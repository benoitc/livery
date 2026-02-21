# Building REST APIs

This guide walks you through building a complete REST API with Livery, including a working example with Docker and curl test commands.

## API Structure

A typical REST API has these endpoints:

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/users | List all users |
| GET | /api/users/:id | Get a user |
| POST | /api/users | Create a user |
| PUT | /api/users/:id | Update a user |
| DELETE | /api/users/:id | Delete a user |

## Application Setup

### rest_api_app.erl

```erlang
-module(rest_api_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Routes = [
        {get, "/api/users", users_list_handler, #{}},
        {get, "/api/users/:id", users_get_handler, #{}},
        {post, "/api/users", users_create_handler, #{}},
        {put, "/api/users/:id", users_update_handler, #{}},
        {delete, "/api/users/:id", users_delete_handler, #{}}
    ],
    Router = livery_router:compile(Routes),

    {ok, _} = livery:start_listener(rest_api, #{
        port => 8080,
        handler => livery_routing_handler,
        handler_opts => #{router => Router}
    }),

    rest_api_sup:start_link().

stop(_State) ->
    livery:stop_listener(rest_api),
    ok.
```

## Handler Implementations

### List Users Handler

```erlang
-module(users_list_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, State) ->
    %% Parse pagination from query string
    Page = parse_int(livery_helpers:get_qs_value(<<"page">>, Req, <<"1">>)),
    Limit = parse_int(livery_helpers:get_qs_value(<<"limit">>, Req, <<"20">>)),

    %% Fetch users (replace with your data access)
    Users = fetch_users(Page, Limit),

    livery_helpers:reply_json(200, #{
        data => Users,
        page => Page,
        limit => Limit
    }, State).

parse_int(Bin) ->
    try binary_to_integer(Bin)
    catch _:_ -> 1
    end.

fetch_users(_Page, _Limit) ->
    %% In a real app, query your database here
    [
        #{id => 1, name => <<"Alice">>, email => <<"alice@example.com">>},
        #{id => 2, name => <<"Bob">>, email => <<"bob@example.com">>}
    ].
```

### Get User Handler

```erlang
-module(users_get_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(_Req, Opts) ->
    UserId = livery_helpers:binding(<<"id">>, Opts),

    case fetch_user(UserId) of
        {ok, User} ->
            livery_helpers:reply_json(200, User, Opts);
        {error, not_found} ->
            livery_helpers:reply_json(404, #{error => <<"User not found">>}, Opts)
    end.

fetch_user(<<"1">>) ->
    {ok, #{id => 1, name => <<"Alice">>, email => <<"alice@example.com">>}};
fetch_user(<<"2">>) ->
    {ok, #{id => 2, name => <<"Bob">>, email => <<"bob@example.com">>}};
fetch_user(_) ->
    {error, not_found}.
```

### Create User Handler

```erlang
-module(users_create_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, State) ->
    case livery_helpers:json_body(Req) of
        {ok, #{<<"name">> := Name, <<"email">> := Email}}
          when is_binary(Name), is_binary(Email) ->
            %% Create user (replace with your logic)
            User = create_user(Name, Email),
            livery_helpers:reply_json(201, User, State);
        {ok, _} ->
            livery_helpers:reply_json(400, #{
                error => <<"validation_error">>,
                message => <<"name and email are required">>
            }, State);
        {error, _} ->
            livery_helpers:reply_json(400, #{
                error => <<"invalid_json">>,
                message => <<"Request body must be valid JSON">>
            }, State)
    end.

create_user(Name, Email) ->
    #{
        id => erlang:unique_integer([positive]),
        name => Name,
        email => Email
    }.
```

### Update User Handler

```erlang
-module(users_update_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, Opts) ->
    UserId = livery_helpers:binding(<<"id">>, Opts),

    case livery_helpers:json_body(Req) of
        {ok, Updates} when is_map(Updates) ->
            case update_user(UserId, Updates) of
                {ok, User} ->
                    livery_helpers:reply_json(200, User, Opts);
                {error, not_found} ->
                    livery_helpers:reply_json(404, #{error => <<"User not found">>}, Opts)
            end;
        _ ->
            livery_helpers:reply_json(400, #{error => <<"Invalid JSON">>}, Opts)
    end.

update_user(<<"1">>, Updates) ->
    Base = #{id => 1, name => <<"Alice">>, email => <<"alice@example.com">>},
    {ok, maps:merge(Base, Updates)};
update_user(<<"2">>, Updates) ->
    Base = #{id => 2, name => <<"Bob">>, email => <<"bob@example.com">>},
    {ok, maps:merge(Base, Updates)};
update_user(_, _) ->
    {error, not_found}.
```

### Delete User Handler

```erlang
-module(users_delete_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(_Req, Opts) ->
    UserId = livery_helpers:binding(<<"id">>, Opts),

    case delete_user(UserId) of
        ok ->
            {reply, 204, [], Opts};
        {error, not_found} ->
            livery_helpers:reply_json(404, #{error => <<"User not found">>}, Opts)
    end.

delete_user(<<"1">>) -> ok;
delete_user(<<"2">>) -> ok;
delete_user(_) -> {error, not_found}.
```

## Docker Setup

### Dockerfile

```dockerfile
FROM erlang:27-alpine

WORKDIR /app

# Copy rebar config and fetch deps
COPY rebar.config rebar.lock ./
RUN rebar3 compile || true

# Copy source and build release
COPY . .
RUN rebar3 release

EXPOSE 8080

CMD ["_build/default/rel/rest_api/bin/rest_api", "foreground"]
```

### docker-compose.yml

```yaml
version: '3.8'
services:
  rest_api:
    build: .
    ports:
      - "8080:8080"
    environment:
      - ERLANG_COOKIE=secret
```

### Build and Run

```bash
# Build the Docker image
docker-compose build

# Start the container
docker-compose up -d

# View logs
docker-compose logs -f

# Stop
docker-compose down
```

## Testing with curl

### List Users

```bash
curl http://localhost:8080/api/users
# {"data":[{"id":1,"name":"Alice","email":"alice@example.com"},{"id":2,"name":"Bob","email":"bob@example.com"}],"page":1,"limit":20}
```

### List Users with Pagination

```bash
curl "http://localhost:8080/api/users?page=2&limit=10"
```

### Get User

```bash
curl http://localhost:8080/api/users/1
# {"id":1,"name":"Alice","email":"alice@example.com"}
```

### Get Non-existent User

```bash
curl http://localhost:8080/api/users/999
# {"error":"User not found"}
```

### Create User

```bash
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Charlie","email":"charlie@example.com"}'
# {"id":123456,"name":"Charlie","email":"charlie@example.com"}
```

### Create User with Validation Error

```bash
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Charlie"}'
# {"error":"validation_error","message":"name and email are required"}
```

### Update User

```bash
curl -X PUT http://localhost:8080/api/users/1 \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice Smith"}'
# {"id":1,"name":"Alice Smith","email":"alice@example.com"}
```

### Delete User

```bash
curl -X DELETE http://localhost:8080/api/users/1 -v
# < HTTP/1.1 204 No Content
```

## Error Handling Pattern

Create a reusable error handling module:

```erlang
-module(api_errors).
-export([
    not_found/2,
    bad_request/2,
    validation_error/3,
    internal_error/1
]).

not_found(Resource, State) ->
    livery_helpers:reply_json(404, #{
        error => <<"not_found">>,
        message => iolist_to_binary([Resource, " not found"])
    }, State).

bad_request(Message, State) ->
    livery_helpers:reply_json(400, #{
        error => <<"bad_request">>,
        message => Message
    }, State).

validation_error(Field, Reason, State) ->
    livery_helpers:reply_json(422, #{
        error => <<"validation_error">>,
        field => Field,
        message => Reason
    }, State).

internal_error(State) ->
    livery_helpers:reply_json(500, #{
        error => <<"internal_error">>,
        message => <<"Something went wrong">>
    }, State).
```

## Adding Authentication

See [Middleware](middleware.md) for adding authentication to your API.
