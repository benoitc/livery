%% @doc Public API for Livery HTTP server.
%%
%% Livery is a high-performance HTTP/1.1, HTTP/2, HTTP/3 server for Erlang/OTP 27+.
%%
%% Example:
%% ```
%% %% Start a basic HTTP server
%% {ok, _} = livery:start_listener(my_http, #{
%%     port => 8080,
%%     handler => my_handler
%% }).
%%
%% %% Start an HTTPS server
%% {ok, _} = livery:start_listener(my_https, #{
%%     port => 8443,
%%     handler => my_handler,
%%     ssl_opts => [
%%         {certfile, "cert.pem"},
%%         {keyfile, "key.pem"}
%%     ]
%% }).
%%
%% %% Start an HTTP/3 server (QUIC)
%% {ok, _} = livery:start_h3_listener(my_h3, #{
%%     port => 8443,
%%     handler => my_handler,
%%     cert => CertDer,
%%     key => KeyDer
%% }).
%% '''
-module(livery).

-export([
    start_listener/2,
    stop_listener/1,
    which_listeners/0,
    %% HTTP/3 (QUIC)
    start_h3_listener/2,
    stop_h3_listener/1,
    which_h3_listeners/0
]).

-type listener_opts() :: #{
    port := inet:port_number(),
    handler := module(),
    handler_opts => term(),
    num_acceptors => pos_integer() | auto,
    ssl_opts => list()
}.

-type h3_listener_opts() :: #{
    port := inet:port_number(),
    handler := module(),
    handler_opts => term(),
    cert := binary(),           % DER-encoded certificate
    key := binary() | term(),   % DER-encoded private key or key term
    pool_size => pos_integer()  % Number of listener processes (default: scheduler count)
}.

-export_type([listener_opts/0, h3_listener_opts/0]).

%% @doc Start a new HTTP listener.
%%
%% Options:
%% - `port' (required): The port to listen on
%% - `handler' (required): Handler module implementing `livery_handler' behaviour
%% - `handler_opts': Options passed to handler's init/2
%% - `num_acceptors': Number of acceptor processes (default: auto = scheduler count)
%% - `ssl_opts': SSL options for HTTPS (if not provided, plain HTTP)
%%
%% Example:
%% ```
%% {ok, _} = livery:start_listener(my_http, #{
%%     port => 8080,
%%     handler => my_handler,
%%     handler_opts => #{key => value}
%% }).
%% '''
-spec start_listener(Name :: atom(), Opts :: listener_opts()) ->
    {ok, pid()} | {error, term()}.
start_listener(Name, Opts) ->
    validate_opts(Opts),
    livery_sup:start_listener(Name, Opts).

%% @doc Stop a listener.
-spec stop_listener(Name :: atom()) -> ok | {error, term()}.
stop_listener(Name) ->
    livery_sup:stop_listener(Name).

%% @doc Get list of running listeners.
-spec which_listeners() -> [atom()].
which_listeners() ->
    [Name || {Name, _Pid, supervisor, _} <- supervisor:which_children(livery_sup)].

%%====================================================================
%% HTTP/3 (QUIC) API
%%====================================================================

%% @doc Start an HTTP/3 listener using QUIC transport.
%%
%% Options:
%% - `port' (required): The UDP port to listen on
%% - `handler' (required): Handler module implementing `livery_handler' behaviour
%% - `handler_opts': Options passed to handler's init/2
%% - `cert' (required): DER-encoded certificate binary
%% - `key' (required): DER-encoded private key or key term
%% - `pool_size': Number of listener processes (default: scheduler count)
%%
%% Example:
%% ```
%% {ok, CertDer} = file:read_file("cert.der"),
%% {ok, KeyDer} = file:read_file("key.der"),
%% {ok, _} = livery:start_h3_listener(my_h3, #{
%%     port => 8443,
%%     handler => my_handler,
%%     cert => CertDer,
%%     key => KeyDer
%% }).
%% '''
-spec start_h3_listener(Name :: atom(), Opts :: h3_listener_opts()) ->
    {ok, pid()} | {error, term()}.
start_h3_listener(Name, Opts) ->
    validate_h3_opts(Opts),
    Port = maps:get(port, Opts),
    Handler = maps:get(handler, Opts),
    HandlerOpts = maps:get(handler_opts, Opts, #{}),
    Cert = maps:get(cert, Opts),
    Key = maps:get(key, Opts),
    PoolSize = maps:get(pool_size, Opts, erlang:system_info(schedulers)),

    %% Build QUIC server options
    QuicOpts = #{
        cert => Cert,
        key => Key,
        alpn => [<<"h3">>],
        pool_size => PoolSize,
        connection_handler => fun(_ConnPid, ConnRef) ->
            %% Start HTTP/3 handler for this connection
            quic:set_owner(ConnRef, self()),
            {ok, H3Pid} = livery_h3:start_link(ConnRef, Handler, HandlerOpts),
            quic:set_owner(ConnRef, H3Pid),
            {ok, H3Pid}
        end
    },

    quic:start_server(Name, Port, QuicOpts).

%% @doc Stop an HTTP/3 listener.
-spec stop_h3_listener(Name :: atom()) -> ok | {error, term()}.
stop_h3_listener(Name) ->
    quic:stop_server(Name).

%% @doc Get list of running HTTP/3 listeners.
-spec which_h3_listeners() -> [atom()].
which_h3_listeners() ->
    quic:which_servers().

%%====================================================================
%% Internal functions
%%====================================================================

validate_opts(Opts) ->
    case maps:is_key(port, Opts) of
        true -> ok;
        false -> error({missing_option, port})
    end,
    case maps:is_key(handler, Opts) of
        true -> ok;
        false -> error({missing_option, handler})
    end,
    ok.

validate_h3_opts(Opts) ->
    validate_opts(Opts),
    case maps:is_key(cert, Opts) of
        true -> ok;
        false -> error({missing_option, cert})
    end,
    case maps:is_key(key, Opts) of
        true -> ok;
        false -> error({missing_option, key})
    end,
    ok.
