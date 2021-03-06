%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_ct_helpers).

-include_lib("common_test/include/ct.hrl").

-export([
    log_environment/0,
    run_steps/2,
    run_setup_steps/2,
    run_teardown_steps/1,
    ensure_application_srcdir/3,
    make_verbosity/0,
    start_long_running_testsuite_monitor/1,
    stop_long_running_testsuite_monitor/1,
    testcase_started/2,
    testcase_finished/2,
    control_action/2, control_action/3, control_action/4,
    control_action_t/3, control_action_t/4, control_action_t/5,
    control_action_opts/1,
    info_action/3,
    info_action_t/4,
    run_cmd/1,
    run_cmd_and_capture_output/1,
    get_config/2,
    set_config/2,
    get_node_config/2
  ]).

-define(DEFAULT_USER, "guest").
-define(SSL_CERT_PASSWORD, "test").
-define(NODE_START_ATTEMPTS, 10).
-define(TCP_PORTS_BASE, 21000).
-define(TCP_PORTS_LIST, [
    tcp_port_amqp,
    tcp_port_amqp_tls,
    tcp_port_mgmt,
    tcp_port_erlang_dist
  ]).

%% -------------------------------------------------------------------
%% Testsuite internal helpers.
%% -------------------------------------------------------------------

log_environment() ->
    Vars = lists:sort(fun(A, B) -> A =< B end, os:getenv()),
    ct:pal("Environment variable:~n~s", [
        [io_lib:format("  ~s~n", [V]) || V <- Vars]]).

run_setup_steps(Suite, Config) ->
    Config1 = set_config(Config, {ct_suite, Suite}),
    Steps = [
      fun ensure_rabbit_common_srcdir/1,
      fun ensure_erlang_mk_depsdir/1,
      fun ensure_rabbit_srcdir/1,
      fun ensure_make_cmd/1,
      fun ensure_rabbitmqctl_cmd/1,
      fun ensure_ssl_certs/1,
      fun start_rabbitmq_nodes/1,
      fun start_long_running_testsuite_monitor/1
    ],
    run_steps(Config1, Steps).

run_teardown_steps(Config) ->
    Steps = [
      fun stop_long_running_testsuite_monitor/1,
      fun stop_rabbitmq_nodes/1
    ],
    run_steps(Config, Steps).

run_steps(Config, [Step | Rest]) ->
    case Step(Config) of
        {skip, _} = Error -> Error;
        Config1           -> run_steps(Config1, Rest)
    end;
run_steps(Config, []) ->
    Config.

run_node_steps(Config, NodeConfig, I, [Step | Rest]) ->
    case Step(Config, NodeConfig, I) of
        {skip, _} = Error -> Error;
        NodeConfig1       -> run_node_steps(Config, NodeConfig1, I, Rest)
    end;
run_node_steps(_, NodeConfig, _, []) ->
    NodeConfig.

ensure_rabbit_common_srcdir(Config) ->
    Path = case get_config(Config, rabbit_common_srcdir) of
        undefined ->
            filename:dirname(
              filename:dirname(
                code:which(?MODULE)));
        P ->
            P
    end,
    case filelib:is_dir(Path) of
        true  -> set_config(Config, {rabbit_common_srcdir, Path});
        false -> {skip,
                  "rabbit_common source directory required, " ++
                  "please set 'rabbit_common_srcdir' in ct config"}
    end.

ensure_erlang_mk_depsdir(Config) ->
    Path = case get_config(Config, erlang_mk_depsdir) of
        undefined ->
            case os:getenv("DEPS_DIR") of
                false ->
                    %% Try the common locations.
                    SrcDir = ?config(rabbit_common_srcdir, Config),
                    Ds = [
                      filename:join(SrcDir, "deps"),
                      filename:join(SrcDir, "../../deps")
                    ],
                    case lists:filter(fun filelib:is_dir/1, Ds) of
                        [P |_] -> P;
                        []     -> false
                    end;
                P ->
                    P
            end;
        P ->
            P
    end,
    case Path =/= false andalso filelib:is_dir(Path) of
        true  -> set_config(Config, {erlang_mk_depsdir, Path});
        false -> {skip,
                  "deps directory required, " ++
                  "please set DEPSD_DIR or 'erlang_mk_depsdir' " ++
                  "in ct config"}
    end.

ensure_rabbit_srcdir(Config) ->
    ensure_application_srcdir(Config, rabbit, rabbit).

ensure_application_srcdir(Config, App, Module) ->
    AppS = atom_to_list(App),
    Key = list_to_atom(AppS ++ "_srcdir"),
    Path = case get_config(Config, Key) of
        undefined ->
            case code:which(Module) of
                non_existing ->
                    filename:join(?config(rabbit_common_srcdir, Config), AppS);
                P ->
                    filename:dirname(
                      filename:dirname(P))
            end;
        P ->
            P
    end,
    case filelib:is_dir(Path) of
        true  -> set_config(Config, {Key, Path});
        false -> {skip,
                  AppS ++ "source directory required, " ++
                  "please set '" ++ AppS ++ "_srcdir' in ct config"}
    end.

ensure_make_cmd(Config) ->
    Make = case get_config(Config, make_cmd) of
        undefined ->
            case os:getenv("MAKE") of
                false -> "make";
                M     -> M
            end;
        M ->
            M
    end,
    Make1 = "\"" ++ Make ++ "\"",
    Cmd = Make1 ++ " --version | grep -q 'GNU Make'",
    case run_cmd(Cmd) of
        true -> set_config(Config, {make_cmd, Make1});
        _    -> {skip,
                 "GNU Make required, " ++
                 "please set MAKE or 'make_cmd' in ct config"}
    end.

ensure_rabbitmqctl_cmd(Config) ->
    Rabbitmqctl = case get_config(Config, rabbitmqctl_cmd) of
        undefined ->
            case os:getenv("RABBITMQCTL") of
                false ->
                    SrcDir = ?config(rabbit_srcdir, Config),
                    R = filename:join(SrcDir, "scripts/rabbitmqctl"),
                    case filelib:is_file(R) of
                        true  -> R;
                        false -> false
                    end;
                R ->
                    R
            end;
        R ->
            R
    end,
    Error = {skip, "rabbitmqctl required, " ++
             "please set RABBITMQCTL or 'rabbitmqctl_cmd' in ct config"},
    case Rabbitmqctl of
        false ->
            Error;
        _ ->
            Rabbitmqctl1 = "\"" ++ Rabbitmqctl ++ "\"",
            Cmd = Rabbitmqctl1 ++ " foobar 2>&1 |" ++
              " grep -q 'Error: could not recognise command'",
            case run_cmd(Cmd) of
                true -> set_config(Config, {rabbitmqctl_cmd, Rabbitmqctl1});
                _    -> Error
            end
    end.

ensure_ssl_certs(Config) ->
    Make = ?config(make_cmd, Config),
    SrcDir = ?config(rabbit_common_srcdir, Config),
    CertsMakeDir = filename:join([SrcDir, "tools", "tls-certs"]),
    PrivDir = ?config(priv_dir, Config),
    CertsDir = filename:join(PrivDir, "certs"),
    Cmd = Make ++ " -C " ++ CertsMakeDir ++ make_verbosity() ++
      " PASSWORD='" ++ ?SSL_CERT_PASSWORD ++ "'" ++
      " DIR='" ++ CertsDir ++ "'",
    case run_cmd(Cmd) of
        true ->
            %% Add SSL certs to the broker configuration.
            Config1 = merge_app_env_in_config(Config,
              {rabbit, [
                  {ssl_options, [
                      {cacertfile, filename:join([CertsDir, "testca", "cacert.pem"])},
                      {certfile, filename:join([CertsDir, "server", "cert.pem"])},
                      {keyfile, filename:join([CertsDir, "server", "key.pem"])},
                      {verify, verify_peer},
                      {fail_if_no_peer_cert, true}
                    ]}]}),
            set_config(Config1, {rmq_certsdir, CertsDir});
        false ->
            {skip, "Failed to create SSL certificates"}
    end.

start_rabbitmq_nodes(Config) ->
    Config1 = set_config(Config,
                         [{rmq_username, list_to_binary(?DEFAULT_USER)},
                          {rmq_password, list_to_binary(?DEFAULT_USER)},
                          {rmq_hostname, "localhost"},
                          {rmq_vhost, <<"/">>},
                          {rmq_channel_max, 0}]),
    {NodesCount, Clustered} = case get_config(Config1, rmq_nodes_count) of
        undefined ->
            {1, false};
        {N, C} when is_integer(N) andalso N >= 1 andalso is_boolean(C) ->
            {N, C}
    end,
    Master = self(),
    Starters = [
      spawn_link(fun() -> start_rabbitmq_node(Master, Config1, [], I) end)
      || I <- lists:seq(0, NodesCount - 1)
    ],
    wait_for_rabbitmq_nodes(Config1, Starters, [], Clustered).

wait_for_rabbitmq_nodes(Config, [], NodeConfigs, Clustered) ->
    Config1 = set_config(Config, {rmq_nodes, NodeConfigs}),
    if
        Clustered ->
            Rabbitmqctl = ?config(rabbitmqctl_cmd, Config),
            Nodename = ?config(rmq_nodename, hd(NodeConfigs)),
            Cmd = Rabbitmqctl ++ " -n \"" ++ atom_to_list(Nodename) ++ "\"" ++
            " cluster_status",
            case rabbit_ct_helpers:run_cmd(Cmd) of
                true ->
                    Config1;
                false ->
                    stop_rabbitmq_nodes(Config1),
                    {skip, "Could not confirm cluster was up and running"}
            end;
        true ->
            Config1
    end;
wait_for_rabbitmq_nodes(Config, Starting, NodeConfigs, Clustered) ->
    receive
        {_, {skip, _} = Error} ->
            Config1 = set_config(Config, {rmq_nodes, NodeConfigs}),
            stop_rabbitmq_nodes(Config1),
            Error;
        {Pid, NodeConfig} when NodeConfigs =:= [] ->
            wait_for_rabbitmq_nodes(Config, Starting -- [Pid],
              [NodeConfig | NodeConfigs], Clustered);
        {Pid, NodeConfig} when not Clustered ->
            wait_for_rabbitmq_nodes(Config, Starting -- [Pid],
              [NodeConfig | NodeConfigs], Clustered);
        {Pid, NodeConfig} when Clustered ->
            case cluster_nodes(Config, NodeConfig, hd(NodeConfigs)) of
                ok ->
                    wait_for_rabbitmq_nodes(Config, Starting -- [Pid],
                      [NodeConfig | NodeConfigs], Clustered);
                {skip, _} = Error ->
                    Config1 = set_config(Config,
                      {rmq_nodes, [NodeConfig | NodeConfigs]}),
                    stop_rabbitmq_nodes(Config1),
                    Error
            end
    end.

%% To start a RabbitMQ node, we need to:
%%   1. Pick TCP port numbers
%%   2. Generate a node name
%%   3. Write a configuration file
%%   4. Start the node
%%
%% If this fails (usually because the node name is taken or a TCP port
%% is already in use), we start again with another set of TCP ports. The
%% node name is derived from the AMQP TCP port so a new node name is
%% generated.

start_rabbitmq_node(Master, Config, NodeConfig, I) ->
    Attempts = case get_config(NodeConfig, rmq_failed_boot_attempts) of
        undefined -> 0;
        N         -> N
    end,
    NodeConfig1 = init_tcp_port_numbers(Config, NodeConfig, I),
    NodeConfig2 = init_nodename(Config, NodeConfig1, I),
    NodeConfig3 = init_config_filename(Config, NodeConfig2, I),
    Steps = [
      fun write_config_file/3,
      fun do_start_rabbitmq_node/3
    ],
    case run_node_steps(Config, NodeConfig3, I, Steps) of
        {skip, _} = Error
        when Attempts >= ?NODE_START_ATTEMPTS ->
            %% It's unlikely we'll ever succeed to start RabbitMQ.
            Master ! {self(), Error},
            unlink(Master);
        {skip, _} ->
            %% Try again with another TCP port numbers base.
            NodeConfig4 = move_nonworking_nodedir_away(NodeConfig3),
            NodeConfig5 = set_config(NodeConfig4,
              {rmq_failed_boot_attempts, Attempts + 1}),
            start_rabbitmq_node(Master, Config, NodeConfig5, I);
        NodeConfig4 ->
            Master ! {self(), NodeConfig4},
            unlink(Master)
    end.

init_tcp_port_numbers(_Config, NodeConfig, I) ->
    %% If there is no TCP port numbers base previously calculated,
    %% use the TCP port 21000. If a base was previously calculated,
    %% increment it by the number of TCP ports we may open.
    %%
    %% Port 21000 is an arbitrary choice. We don't want to use the
    %% default AMQP port of 5672 so other AMQP clients on the same host
    %% do not accidentally use the testsuite broker. There seems to be
    %% no registered service around this port in /etc/services. And it
    %% should be far enough away from the default ephemeral TCP ports
    %% range.
    TcpPortsCount = length(?TCP_PORTS_LIST),
    Base = case get_config(NodeConfig, tcp_ports_base) of
        undefined -> ?TCP_PORTS_BASE + I * TcpPortsCount * ?NODE_START_ATTEMPTS;
        P         -> P + TcpPortsCount
    end,
    NodeConfig1 = set_config(NodeConfig, {tcp_ports_base, Base}),
    %% Now, compute all TCP port numbers from this base.
    {NodeConfig2, _} = lists:foldl(
      fun(PortName, {NewConfig, NextPort}) ->
          {
            set_config(NewConfig, {PortName, NextPort}),
            NextPort + 1
          }
      end,
      {NodeConfig1, Base}, ?TCP_PORTS_LIST),
    %% Finally, update the RabbitMQ configuration with the computed TCP
    %% port numbers.
    update_tcp_ports_in_rmq_config(NodeConfig2, ?TCP_PORTS_LIST).

update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_amqp = Key | Rest]) ->
    NodeConfig1 = merge_app_env_in_config(NodeConfig,
      {rabbit, [{tcp_listeners, [?config(Key, NodeConfig)]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_amqp_tls = Key | Rest]) ->
    NodeConfig1 = merge_app_env_in_config(NodeConfig,
      {rabbit, [{ssl_listeners, [?config(Key, NodeConfig)]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_mgmt = Key | Rest]) ->
    NodeConfig1 = merge_app_env_in_config(NodeConfig,
      {rabbitmq_management, [{listener, [{port, ?config(Key, NodeConfig)}]}]}),
    update_tcp_ports_in_rmq_config(NodeConfig1, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, [tcp_port_erlang_dist | Rest]) ->
    %% The Erlang distribution port doesn't appear in the configuration file.
    update_tcp_ports_in_rmq_config(NodeConfig, Rest);
update_tcp_ports_in_rmq_config(NodeConfig, []) ->
    NodeConfig.

init_nodename(Config, NodeConfig, I) ->
    Base = ?config(tcp_ports_base, NodeConfig),
    Nodename = list_to_atom(
      rabbit_misc:format(
        "rmq-ct-~s-~b-~b@localhost",
        [?config(ct_suite, Config), I + 1, Base])),
    set_config(NodeConfig, {rmq_nodename, Nodename}).

init_config_filename(Config, NodeConfig, _I) ->
    PrivDir = ?config(priv_dir, Config),
    Nodename = ?config(rmq_nodename, NodeConfig),
    ConfigDir = filename:join(PrivDir, Nodename),
    ConfigFile = filename:join(ConfigDir, Nodename),
    set_config(NodeConfig, {erlang_node_config_filename, ConfigFile}).

write_config_file(Config, NodeConfig, _I) ->
    %% Prepare a RabbitMQ configuration.
    ErlangConfigBase = ?config(erlang_node_config, Config),
    ErlangConfigOverlay = ?config(erlang_node_config, NodeConfig),
    ErlangConfig = merge_app_env(ErlangConfigBase, ErlangConfigOverlay),
    ConfigFile = ?config(erlang_node_config_filename, NodeConfig),
    ConfigDir = filename:dirname(ConfigFile),
    Ret1 = file:make_dir(ConfigDir),
    Ret2 = file:write_file(ConfigFile ++ ".config",
                          io_lib:format("% vim:ft=erlang:~n~n~p.~n",
                                        [ErlangConfig])),
    case {Ret1, Ret2} of
        {ok, ok} ->
            NodeConfig;
        {{error, eexist}, ok} ->
            NodeConfig;
        {{error, Reason}, _} when Reason =/= eexist ->
            {skip, "Failed to create Erlang node config directory \"" ++
             ConfigDir ++ "\": " ++ file:format_error(Reason)};
        {_, {error, Reason}} ->
            {skip, "Failed to create Erlang node config file \"" ++
             ConfigFile ++ "\": " ++ file:format_error(Reason)}
    end.

do_start_rabbitmq_node(Config, NodeConfig, _I) ->
    Make = ?config(make_cmd, Config),
    SrcDir = ?config(rabbit_srcdir, Config),
    PrivDir = ?config(priv_dir, Config),
    Nodename = ?config(rmq_nodename, NodeConfig),
    DistPort = ?config(tcp_port_erlang_dist, NodeConfig),
    ConfigFile = ?config(erlang_node_config_filename, NodeConfig),
    Cmd = Make ++ " -C " ++ SrcDir ++ make_verbosity() ++
      " start-background-broker" ++
      " RABBITMQ_NODENAME='" ++ atom_to_list(Nodename) ++ "'" ++
      " RABBITMQ_DIST_PORT='" ++ integer_to_list(DistPort) ++ "'" ++
      " RABBITMQ_CONFIG_FILE='" ++ ConfigFile ++ "'" ++
      " TEST_TMPDIR='" ++ PrivDir ++ "'",
    case run_cmd(Cmd) of
        true  -> NodeConfig;
        false -> {skip, "Failed to initialize RabbitMQ"}
    end.

cluster_nodes(Config, NodeConfig1, NodeConfig2) ->
    Rabbitmqctl = ?config(rabbitmqctl_cmd, Config),
    Nodename1 = ?config(rmq_nodename, NodeConfig1),
    Nodename2 = ?config(rmq_nodename, NodeConfig2),
    Cmd =
      Rabbitmqctl ++ " -n \"" ++ atom_to_list(Nodename1) ++ "\"" ++
      " stop_app && " ++
      Rabbitmqctl ++ " -n \"" ++ atom_to_list(Nodename1) ++ "\"" ++
      " join_cluster \"" ++ atom_to_list(Nodename2) ++ "\" && " ++
      Rabbitmqctl ++ " -n \"" ++ atom_to_list(Nodename1) ++ "\"" ++
      " start_app",
    case rabbit_ct_helpers:run_cmd(Cmd) of
        true  -> ok;
        false -> {skip,
                  "Failed to cluster nodes \"" ++ atom_to_list(Nodename1) ++
                  "\" and \"" ++ atom_to_list(Nodename2) ++ "\""}
    end.

move_nonworking_nodedir_away(NodeConfig) ->
    ConfigFile = ?config(erlang_node_config_filename, NodeConfig),
    ConfigDir = filename:dirname(ConfigFile),
    NewName = filename:join(
      filename:dirname(ConfigDir),
      "_unused_nodedir_" ++ filename:basename(ConfigDir)),
    file:rename(ConfigDir, NewName),
    lists:keydelete(erlang_node_config_filename, 1, NodeConfig).

stop_rabbitmq_nodes(Config) ->
    NodeConfigs = ?config(rmq_nodes, Config),
    [stop_rabbitmq_node(Config, NodeConfig) || NodeConfig <- NodeConfigs],
    Config.

stop_rabbitmq_node(Config, NodeConfig) ->
    Make = ?config(make_cmd, Config),
    SrcDir = ?config(rabbit_srcdir, Config),
    PrivDir = ?config(priv_dir, Config),
    Nodename = ?config(rmq_nodename, NodeConfig),
    Cmd = Make ++ " -C " ++ SrcDir ++ make_verbosity() ++
      " stop-rabbit-on-node stop-node" ++
      " RABBITMQ_NODENAME='" ++ atom_to_list(Nodename) ++ "'" ++
      " TEST_TMPDIR='" ++ PrivDir ++ "'",
    run_cmd(Cmd),
    NodeConfig.

%% -------------------------------------------------------------------
%% Process to log a message every minute during long testcases.
%% -------------------------------------------------------------------

-define(PING_CT_INTERVAL, 60 * 1000). %% In milliseconds.

start_long_running_testsuite_monitor(Config) ->
    Pid = spawn(
      fun() ->
          {ok, TimerRef} = timer:send_interval(?PING_CT_INTERVAL, ping_ct),
          long_running_testsuite_monitor(TimerRef, [])
      end),
    set_config(Config, {long_running_testsuite_monitor, Pid}).

stop_long_running_testsuite_monitor(Config) ->
    ?config(long_running_testsuite_monitor, Config) ! stop,
    Config.

long_running_testsuite_monitor(TimerRef, Testcases) ->
    receive
        {started, Testcase} ->
            Testcases1 = [{Testcase, time_compat:monotonic_time(seconds)}
                          | Testcases],
            long_running_testsuite_monitor(TimerRef, Testcases1);
        {finished, Testcase} ->
            Testcases1 = proplists:delete(Testcase, Testcases),
            long_running_testsuite_monitor(TimerRef, Testcases1);
        ping_ct ->
            T1 = time_compat:monotonic_time(seconds),
            ct:pal("Testcases still in progress:~s",
              [[
                  begin
                      TDiff = format_time_diff(T1, T0),
                      rabbit_misc:format("~n - ~s (~s)", [TC, TDiff])
                  end
                  || {TC, T0} <- Testcases
                ]]),
            long_running_testsuite_monitor(TimerRef, Testcases);
        stop ->
            timer:cancel(TimerRef)
    end.

format_time_diff(T1, T0) ->
    Diff = T1 - T0,
    Hours = Diff div 3600,
    Diff1 = Diff rem 3600,
    Minutes = Diff1 div 60,
    Seconds = Diff1 rem 60,
    rabbit_misc:format("~b:~2..0b:~2..0b", [Hours, Minutes, Seconds]).

testcase_started(Config, Testcase) ->
    Testcase1 = config_to_testcase_name(Config, Testcase),
    ?config(long_running_testsuite_monitor, Config) ! {started, Testcase1},
    Config.

testcase_finished(Config, Testcase) ->
    Testcase1 = config_to_testcase_name(Config, Testcase),
    ?config(long_running_testsuite_monitor, Config) ! {finished, Testcase1},
    Config.

config_to_testcase_name(Config, Testcase) ->
    Name = io_lib:format("~s", [Testcase]),
    case get_config(Config, tc_group_properties) of
        [] ->
            Name;
        Props ->
            Name1 = io_lib:format("~s/~s",
              [proplists:get_value(name, Props), Name]),
            config_to_testcase_name1(Name1, get_config(Config, tc_group_path))
    end.

config_to_testcase_name1(Name, [Props | Rest]) ->
    Name1 = io_lib:format("~s/~s", [proplists:get_value(name, Props), Name]),
    config_to_testcase_name1(Name1, Rest);
config_to_testcase_name1(Name, []) ->
    lists:flatten(Name).

%% -------------------------------------------------------------------
%% Calls to rabbitmqctl from Erlang.
%% -------------------------------------------------------------------

control_action(Command, Args) ->
    control_action(Command, node(), Args, default_options()).

control_action(Command, Args, NewOpts) ->
    control_action(Command, node(), Args,
                   expand_options(default_options(), NewOpts)).

control_action(Command, Node, Args, Opts) ->
    case catch rabbit_control_main:action(
                 Command, Node, Args, Opts,
                 fun (Format, Args1) ->
                         io:format(Format ++ " ...~n", Args1)
                 end) of
        ok ->
            io:format("done.~n"),
            ok;
        {ok, Result} ->
            rabbit_control_misc:print_cmd_result(Command, Result),
            ok;
        Other ->
            io:format("failed.~n"),
            Other
    end.

control_action_t(Command, Args, Timeout) when is_number(Timeout) ->
    control_action_t(Command, node(), Args, default_options(), Timeout).

control_action_t(Command, Args, NewOpts, Timeout) when is_number(Timeout) ->
    control_action_t(Command, node(), Args,
                     expand_options(default_options(), NewOpts),
                     Timeout).

control_action_t(Command, Node, Args, Opts, Timeout) when is_number(Timeout) ->
    case catch rabbit_control_main:action(
                 Command, Node, Args, Opts,
                 fun (Format, Args1) ->
                         io:format(Format ++ " ...~n", Args1)
                 end, Timeout) of
        ok ->
            io:format("done.~n"),
            ok;
        Other ->
            io:format("failed.~n"),
            Other
    end.

control_action_opts(Raw) ->
    NodeStr = atom_to_list(node()),
    case rabbit_control_main:parse_arguments(Raw, NodeStr) of
        {ok, {Cmd, Opts, Args}} ->
            case control_action(Cmd, node(), Args, Opts) of
                ok    -> ok;
                Error -> Error
            end;
        Error ->
            Error
    end.

info_action(Command, Args, CheckVHost) ->
    ok = control_action(Command, []),
    if CheckVHost -> ok = control_action(Command, [], ["-p", "/"]);
       true       -> ok
    end,
    ok = control_action(Command, lists:map(fun atom_to_list/1, Args)),
    {bad_argument, dummy} = control_action(Command, ["dummy"]),
    ok.

info_action_t(Command, Args, CheckVHost, Timeout) when is_number(Timeout) ->
    if CheckVHost -> ok = control_action_t(Command, [], ["-p", "/"], Timeout);
       true       -> ok
    end,
    ok = control_action_t(Command, lists:map(fun atom_to_list/1, Args), Timeout),
    ok.

default_options() -> [{"-p", "/"}, {"-q", "false"}].

expand_options(As, Bs) ->
    lists:foldl(fun({K, _}=A, R) ->
                        case proplists:is_defined(K, R) of
                            true -> R;
                            false -> [A | R]
                        end
                end, Bs, As).

%% -------------------------------------------------------------------
%% Helpers for helpers.
%% -------------------------------------------------------------------

make_verbosity() ->
    case os:getenv("V") of
        false -> "";
        V     -> " V=" ++ V
    end.

run_cmd(Cmd) ->
    case run_cmd_and_capture_output(Cmd) of
        {ok, _}    -> true;
        {error, _} -> false
    end.

run_cmd_and_capture_output(Cmd) ->
    Marker = "COMMAND SUCCESSFUL",
    Cmd1 = "(" ++ Cmd ++ ") && echo " ++ Marker,
    Output = string:strip(string:strip(os:cmd(Cmd1), right, $\n), right, $\r),
    ct:pal("+ ~s~n~s", [Cmd1, Output]),
    %% os:cmd/1 doesn't return the exit status. Therefore, we verify if
    %% our marker was printed.
    case re:run(Output, Marker, [{capture, none}]) of
        match ->
            Output1 = re:replace(Output, "^" ++ Marker ++ "$", "",
                [multiline, {return, list}]),
            {ok, Output1};
        _ ->
            {error, Output}
    end.

%% This is the same as ?config(), except this one doesn't log a warning
%% if the key is missing.
get_config(Config, Key) ->
    proplists:get_value(Key, Config).

set_config(Config, Tuple) when is_tuple(Tuple) ->
    Key = element(1, Tuple),
    lists:keystore(Key, 1, Config, Tuple);
set_config(Config, [Tuple | Rest]) ->
    Config1 = set_config(Config, Tuple),
    set_config(Config1, Rest);
set_config(Config, []) ->
    Config.

get_node_config(Config, I) ->
    NodeConfigs = ?config(rmq_nodes, Config),
    lists:nth(I + 1, NodeConfigs).

merge_app_env_in_config(Config, Env) ->
    ErlangConfig = proplists:get_value(erlang_node_config, Config, []),
    ErlangConfig1 = merge_app_env(ErlangConfig, Env),
    set_config(Config, {erlang_node_config, ErlangConfig1}).

merge_app_env(ErlangConfig, {App, Env}) ->
    AppConfig = proplists:get_value(App, ErlangConfig, []),
    AppConfig1 = lists:foldl(
      fun({Key, _} = Tuple, AC) ->
          lists:keystore(Key, 1, AC, Tuple)
      end, AppConfig, Env),
    lists:keystore(App, 1, ErlangConfig, {App, AppConfig1});
merge_app_env(ErlangConfig, [Env | Rest]) ->
    ErlangConfig1 = merge_app_env(ErlangConfig, Env),
    merge_app_env(ErlangConfig1, Rest);
merge_app_env(ErlangConfig, []) ->
    ErlangConfig.
