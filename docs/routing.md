# Routing

Livery includes a fast prefix-tree router supporting static paths, dynamic segments, wildcards, and method-based routing.

## Basic Router Setup

```erlang
%% Define routes
Routes = [
    {get, "/", home_handler, #{}},
    {get, "/users", users_list_handler, #{}},
    {get, "/users/:id", user_handler, #{}},
    {post, "/users", user_create_handler, #{}},
    {put, "/users/:id", user_update_handler, #{}},
    {delete, "/users/:id", user_delete_handler, #{}},
    {'_', "/api/*path", api_handler, #{}}  % Any method, wildcard path
],

%% Compile routes
Router = livery_router:compile(Routes).
```

## Route Syntax

### Static Paths

```erlang
{get, "/users/list", handler, #{}}
{get, "/about", handler, #{}}
```

### Dynamic Segments

Use `:name` to capture path segments:

```erlang
{get, "/users/:id", user_handler, #{}}
{get, "/posts/:post_id/comments/:comment_id", comment_handler, #{}}
```

Access bindings in your handler:

```erlang
handle(Req, Opts) ->
    UserId = livery_helpers:binding(<<"id">>, Opts),
    %% ...
```

### Wildcards

Use `*name` to capture the rest of the path:

```erlang
{get, "/files/*path", file_handler, #{}}
% /files/images/logo.png -> path = <<"images/logo.png">>
```

### Method Routing

Supported methods: `get`, `post`, `put`, `delete`, `patch`, `head`, `options`, `connect`, `trace`

Use `'_'` to match any method:

```erlang
{'_', "/api/*path", api_handler, #{}}
```

## Using the Routing Handler

The `livery_routing_handler` module integrates the router with your handlers automatically:

```erlang
%% Define routes
Routes = [
    {get, "/", home_handler, #{}},
    {get, "/users/:id", user_handler, #{}},
    {post, "/users", user_create_handler, #{}}
],
Router = livery_router:compile(Routes),

%% Start listener with routing handler
livery:start_listener(my_http, #{
    port => 8080,
    handler => livery_routing_handler,
    handler_opts => #{
        router => Router,
        not_found_handler => my_404_handler  % optional
    }
}).
```

Your individual handlers receive bindings in their opts:

```erlang
-module(user_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    %% Opts contains #{bindings => #{<<"id">> => <<"123">>}}
    {ok, Req, Opts}.

handle(Req, Opts) ->
    UserId = livery_helpers:binding(<<"id">>, Opts),
    %% Fetch and return user...
    livery_helpers:reply_json(200, #{id => UserId}, Opts).
```

## Manual Routing

You can also use the router directly in your handler:

```erlang
-module(my_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, #{router => maps:get(router, Opts)}}.

handle(Req, #{router := Router} = State) ->
    Method = livery_req:method(Req),
    Path = livery_req:path(Req),

    case livery_router:match(Router, Method, Path) of
        {ok, Handler, Opts, Bindings} ->
            %% Delegate to matched handler
            MergedOpts = Opts#{bindings => Bindings},
            Handler:handle(Req, MergedOpts);
        {error, not_found} ->
            {reply, 404, [], <<"Not Found">>, State}
    end.
```

## Dynamic Route Management

```erlang
%% Add route at runtime
Router2 = livery_router:add_route({get, "/new", new_handler, #{}}, Router),

%% Remove route
Router3 = livery_router:remove_route({get, "/old"}, Router2).
```

## Route Priorities

The router matches routes in this order:

1. Static segments (exact match)
2. Dynamic segments (`:name`)
3. Wildcard segments (`*name`)

For the same path pattern, the first defined route wins.

## Example: API Versioning

```erlang
Routes = [
    %% Version 1
    {get, "/api/v1/users", users_v1_handler, #{}},
    {get, "/api/v1/users/:id", user_v1_handler, #{}},

    %% Version 2
    {get, "/api/v2/users", users_v2_handler, #{}},
    {get, "/api/v2/users/:id", user_v2_handler, #{}},

    %% Catch-all for unversioned API
    {'_', "/api/*path", api_handler, #{}}
].
```

## Custom 404 Handler

```erlang
-module(my_404_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, State) ->
    Path = livery_req:path(Req),
    Body = io_lib:format("Page not found: ~s", [Path]),
    livery_helpers:reply_html(404, iolist_to_binary(Body), State).
```

Use it with the routing handler:

```erlang
livery:start_listener(my_http, #{
    port => 8080,
    handler => livery_routing_handler,
    handler_opts => #{
        router => Router,
        not_found_handler => my_404_handler
    }
}).
```
