-module(hello_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Port = application:get_env(hello, port, 8080),
    Routes = [
        {get, "/", hello_handler, #{}},
        {get, "/greet/:name", hello_handler, #{}}
    ],
    Router = livery_router:compile(Routes),
    {ok, _} = livery:start_listener(hello_http, #{
        port => Port,
        handler => livery_routing_handler,
        handler_opts => #{router => Router}
    }),
    hello_sup:start_link().

stop(_State) ->
    livery:stop_listener(hello_http),
    ok.
