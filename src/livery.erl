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
%% '''
-module(livery).

-export([
    start_listener/2,
    stop_listener/1,
    which_listeners/0
]).

-type listener_opts() :: #{
    port := inet:port_number(),
    handler := module(),
    handler_opts => term(),
    num_acceptors => pos_integer() | auto,
    ssl_opts => list()
}.

-export_type([listener_opts/0]).

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

%% Internal functions

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
