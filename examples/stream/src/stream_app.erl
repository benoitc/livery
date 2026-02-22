-module(stream_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Port = application:get_env(stream, port, 8089),
    Routes = [
        {get, "/stream", stream_handler, #{action => stream}},
        {get, "/large", stream_handler, #{action => large}},
        {get, "/sse", stream_handler, #{action => sse}},
        {get, "/stream-with-trailers", stream_handler, #{action => trailers}}
    ],
    Router = livery_router:compile(Routes),
    {ok, _} = livery:start_listener(stream_http, #{
        port => Port,
        handler => livery_routing_handler,
        handler_opts => #{router => Router}
    }),
    stream_sup:start_link().

stop(_State) ->
    livery:stop_listener(stream_http),
    ok.
