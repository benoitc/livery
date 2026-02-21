-module(ws_example_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Start pg scope for chat room
    pg:start_link(chat),

    %% Define routes
    Routes = [
        {get, "/", index_handler, #{}},
        {get, "/echo", echo_handler, #{}},
        {get, "/chat", chat_handler, #{}}
    ],
    Router = livery_router:compile(Routes),

    %% Start listener
    {ok, _} = livery:start_listener(ws_example, #{
        port => 8080,
        handler => livery_routing_handler,
        handler_opts => #{router => Router}
    }),

    io:format("WebSocket example server started on http://localhost:8080~n"),
    io:format("  - Echo: ws://localhost:8080/echo~n"),
    io:format("  - Chat: ws://localhost:8080/chat?username=yourname~n"),

    ws_example_sup:start_link().

stop(_State) ->
    livery:stop_listener(ws_example),
    ok.
