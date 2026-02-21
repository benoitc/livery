%% @doc Test server management for compliance testing.
%%
%% Starts and stops Livery servers configured for compliance testing:
%% - HTTP/2 server with TLS (for h2spec)
%% - WebSocket server (for Autobahn)
%% - HTTP/1.1 server (for curl)
-module(compliance_server).

-export([
    start_h2_server/1,
    start_ws_server/1,
    start_http_server/1,
    stop_server/1,
    get_free_port/0
]).

%% @doc Start an HTTP/2 server with TLS for h2spec testing.
-spec start_h2_server(Config :: list()) ->
    {ok, Port :: inet:port_number(), Pid :: pid()} | {error, term()}.
start_h2_server(Config) ->
    ProjectRoot = proplists:get_value(project_root, Config),
    CertDir = filename:join([ProjectRoot, "priv", "test_certs"]),

    CertFile = filename:join(CertDir, "server.crt"),
    KeyFile = filename:join(CertDir, "server.key"),

    %% Verify certs exist
    case filelib:is_regular(CertFile) andalso filelib:is_regular(KeyFile) of
        true ->
            Port = get_free_port(),
            SslOpts = [
                {certfile, CertFile},
                {keyfile, KeyFile},
                {alpn_preferred_protocols, [<<"h2">>]}
            ],
            start_listener(h2_compliance_test, Port, compliance_handler, SslOpts);
        false ->
            {error, {certs_not_found, CertDir}}
    end.

%% @doc Start a WebSocket server for Autobahn testing.
-spec start_ws_server(Config :: list()) ->
    {ok, Port :: inet:port_number(), Pid :: pid()} | {error, term()}.
start_ws_server(_Config) ->
    Port = get_free_port(),
    start_listener(ws_compliance_test, Port, ws_echo_handler, []).

%% @doc Start an HTTP/1.1 server for curl testing.
-spec start_http_server(Config :: list()) ->
    {ok, Port :: inet:port_number(), Pid :: pid()} | {error, term()}.
start_http_server(_Config) ->
    Port = get_free_port(),
    start_listener(http_compliance_test, Port, compliance_handler, []).

start_listener(Name, Port, Handler, SslOpts) ->
    Opts = #{
        port => Port,
        handler => Handler,
        num_acceptors => 4
    },
    FullOpts = case SslOpts of
        [] -> Opts;
        _ -> Opts#{ssl_opts => SslOpts}
    end,

    case livery:start_listener(Name, FullOpts) of
        {ok, Pid} ->
            %% Give the listener time to fully start
            timer:sleep(100),
            {ok, Port, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Stop a compliance test server.
-spec stop_server(Pid :: pid() | atom()) -> ok.
stop_server(Pid) when is_pid(Pid) ->
    %% Find the listener name for this pid
    Listeners = livery:which_listeners(),
    lists:foreach(fun(Name) ->
        try
            livery:stop_listener(Name)
        catch
            _:_ -> ok
        end
    end, Listeners),
    ok;
stop_server(Name) when is_atom(Name) ->
    livery:stop_listener(Name).

%% @doc Get a free TCP port.
-spec get_free_port() -> inet:port_number().
get_free_port() ->
    {ok, Listen} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    gen_tcp:close(Listen),
    Port.
