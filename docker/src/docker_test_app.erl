-module(docker_test_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Define routes
    Routes = [
        {get, "/", docker_test_handler, #{action => hello}},
        {get, "/greet/:name", docker_test_handler, #{action => greet}},
        {get, "/stream", docker_test_handler, #{action => stream}},
        {get, "/large", docker_test_handler, #{action => large}},
        {get, "/sse", docker_test_handler, #{action => sse}},
        {get, "/stream-with-trailers", docker_test_handler, #{action => trailers}}
    ],
    Router = livery_router:compile(Routes),
    HandlerOpts = #{router => Router},

    %% Start HTTP/1.1 listener on port 9080
    {ok, _} = livery:start_listener(http1, #{
        port => 9080,
        handler => livery_routing_handler,
        handler_opts => HandlerOpts
    }),
    io:format("Started HTTP/1.1 listener on port 9080~n"),

    %% Start HTTPS/HTTP2 listener on port 9443
    CertFile = get_cert_path("cert.pem"),
    KeyFile = get_cert_path("key.pem"),
    {ok, _} = livery:start_listener(https, #{
        port => 9443,
        handler => livery_routing_handler,
        handler_opts => HandlerOpts,
        ssl_opts => [
            {certfile, CertFile},
            {keyfile, KeyFile},
            {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}
        ]
    }),
    io:format("Started HTTPS/HTTP2 listener on port 9443~n"),

    %% Start HTTP/3 listener on port 9443 (UDP)
    {ok, CertDer} = file:read_file(get_cert_path("cert.der")),
    {ok, KeyDer} = file:read_file(get_cert_path("key.der")),
    {ok, _} = livery:start_h3_listener(http3, #{
        port => 9443,
        handler => livery_routing_handler,
        handler_opts => HandlerOpts,
        cert => CertDer,
        key => KeyDer
    }),
    io:format("Started HTTP/3 listener on port 9443 (UDP)~n"),

    docker_test_sup:start_link().

stop(_State) ->
    livery:stop_listener(http1),
    livery:stop_listener(https),
    livery:stop_h3_listener(http3),
    ok.

%% Internal functions

get_cert_path(Filename) ->
    CertDir = os:getenv("CERT_DIR", "/app/certs"),
    filename:join(CertDir, Filename).
