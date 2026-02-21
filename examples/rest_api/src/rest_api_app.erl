-module(rest_api_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Initialize user store (in-memory for demo)
    ets:new(users, [named_table, public, {keypos, 1}]),
    ets:insert(users, [
        {1, #{id => 1, name => <<"Alice">>, email => <<"alice@example.com">>}},
        {2, #{id => 2, name => <<"Bob">>, email => <<"bob@example.com">>}}
    ]),

    %% Define routes
    Routes = [
        {get, "/api/users", users_list_handler, #{}},
        {get, "/api/users/:id", users_get_handler, #{}},
        {post, "/api/users", users_create_handler, #{}},
        {put, "/api/users/:id", users_update_handler, #{}},
        {delete, "/api/users/:id", users_delete_handler, #{}}
    ],
    Router = livery_router:compile(Routes),

    %% Start listener
    {ok, _} = livery:start_listener(rest_api, #{
        port => 8080,
        handler => livery_routing_handler,
        handler_opts => #{router => Router}
    }),

    io:format("REST API server started on http://localhost:8080~n"),

    rest_api_sup:start_link().

stop(_State) ->
    livery:stop_listener(rest_api),
    ok.
