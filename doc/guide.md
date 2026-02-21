# Livery HTTP Server Guide

Livery is a high-performance HTTP server for Erlang/OTP with support for HTTP/1.1, HTTP/2, and HTTP/3 (QUIC). It features a simple handler-based architecture, built-in routing, middleware support, and WebSocket capabilities.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Architecture Overview](#architecture-overview)
3. [Creating Handlers](#creating-handlers)
4. [Request API](#request-api)
5. [Response Patterns](#response-patterns)
6. [Helper Functions](#helper-functions)
7. [Routing](#routing)
8. [Building REST APIs](#building-rest-apis)
9. [WebSocket Handlers](#websocket-handlers)
10. [Streaming Responses](#streaming-responses)
11. [Middleware](#middleware)
12. [Starting Servers](#starting-servers)
13. [HTTPS & HTTP/3 Configuration](#https--http3-configuration)
14. [Telemetry & Observability](#telemetry--observability)
15. [Configuration Reference](#configuration-reference)

---

## Quick Start

Add Livery to your `rebar.config`:

```erlang
{deps, [
    {livery, {git, "https://github.com/benoitc/livery.git", {branch, "main"}}}
]}.
```

Create a simple handler:

```erlang
-module(hello_handler).
-behaviour(livery_handler).

-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, #{opts => Opts}}.

handle(_Req, State) ->
    {reply, 200, [{<<"content-type">>, <<"text/plain">>}], <<"Hello, World!">>, State}.
```

Start the server:

```erlang
application:ensure_all_started(livery),
livery:start_listener(my_http, #{
    port => 8080,
    handler => hello_handler,
    handler_opts => #{}
}).
```

Your server is now running at `http://localhost:8080`.

---

## Architecture Overview

Livery uses a straightforward architecture:

1. **Listener**: A pool of acceptor processes (default: number of schedulers)
2. **Acceptors**: Use `SO_REUSEPORT` for kernel-level load balancing across processes
3. **Connections**: Each connection spawns a handler process
4. **Handlers**: Your callback module implementing `livery_handler` behaviour

```
┌─────────────┐
│  Listener   │
│   (Pool)    │
└──────┬──────┘
       │ spawns
       ▼
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│  Acceptor 1 │   │  Acceptor 2 │   │  Acceptor N │
│ SO_REUSEPORT│   │ SO_REUSEPORT│   │ SO_REUSEPORT│
└──────┬──────┘   └──────┬──────┘   └──────┬──────┘
       │                 │                 │
       ▼                 ▼                 ▼
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│ Connection  │   │ Connection  │   │ Connection  │
│   Handler   │   │   Handler   │   │   Handler   │
└─────────────┘   └─────────────┘   └─────────────┘
```

**Key Points:**
- Each acceptor listens on the same port using `SO_REUSEPORT`
- The kernel distributes connections across acceptors
- No single-process bottleneck
- Handlers are called directly (no automatic router integration)
- Router is available for use inside handlers

---

## Creating Handlers

Handlers implement the `livery_handler` behaviour:

```erlang
-module(my_handler).
-behaviour(livery_handler).

-export([init/2, handle/2, terminate/2]).

%% Required: Initialize handler state
init(Req, Opts) ->
    %% Opts comes from handler_opts in listener config
    {ok, Req, #{user_data => some_value}}.

%% Required: Handle the request
handle(Req, State) ->
    Method = livery_req:method(Req),
    Path = livery_req:path(Req),
    handle_request(Method, Path, Req, State).

%% Optional: Cleanup on connection close
terminate(_Reason, _State) ->
    ok.

handle_request(<<"GET">>, <<"/health">>, _Req, State) ->
    {reply, 200, [], <<"OK">>, State};
handle_request(_, _, _Req, State) ->
    {reply, 404, [], <<"Not Found">>, State}.
```

### Handler Callbacks

| Callback | Required | Description |
|----------|----------|-------------|
| `init/2` | Yes | Initialize state, return `{ok, Req, State}` |
| `handle/2` | Yes | Process request, return response tuple |
| `terminate/2` | No | Cleanup when connection closes |
| `websocket_handle/2` | No | Handle WebSocket frames |
| `websocket_info/2` | No | Handle Erlang messages during WebSocket |

### Init Return Values

```erlang
{ok, Req, State}           %% Proceed with HTTP handling
{websocket, Req, State}    %% Accept WebSocket upgrade
{error, Reason}            %% Abort request
```

### Handle Return Values

```erlang
{reply, Status, Headers, Body, State}    %% Complete response
{reply, Status, Headers, State}          %% Response with no body
{stream, Status, Headers, StreamFun, State}  %% Chunked streaming
{error, Reason, State}                   %% Error response
```

---

## Request API

The `livery_req` module provides accessors for request data.

### Basic Accessors

```erlang
%% Get HTTP method (binary)
Method = livery_req:method(Req),  % <<"GET">>, <<"POST">>, etc.

%% Get path without query string
Path = livery_req:path(Req),  % <<"/users/123">>

%% Get query string (raw)
QS = livery_req:qs(Req),  % <<"page=1&limit=10">>

%% Get HTTP version
Version = livery_req:version(Req),  % {1, 1}, {2, 0}, or {3, 0}

%% Get all headers as list of tuples
Headers = livery_req:headers(Req),  % [{<<"host">>, <<"example.com">>}, ...]

%% Get specific header
CT = livery_req:header(<<"content-type">>, Req),  % binary() | undefined
CT = livery_req:header(<<"content-type">>, Req, <<"text/plain">>),  % with default

%% Get request body
Body = livery_req:body(Req),  % binary() | undefined

%% Check if request has a body
HasBody = livery_req:has_body(Req),  % true | false

%% Get body length
Length = livery_req:body_length(Req),  % integer | chunked | undefined

%% Get client peer address
{IP, Port} = livery_req:peer(Req),
```

### Convenience Accessors

```erlang
%% Get URL scheme
Scheme = livery_req:scheme(Req),  % http | https

%% Get Host header
Host = livery_req:host(Req),  % <<"example.com">>

%% Get server port
Port = livery_req:port(Req),  % 8080

%% Get Content-Type (stripped of charset/boundary)
CT = livery_req:content_type(Req),  % <<"application/json">>

%% Get Content-Length as integer
Len = livery_req:content_length(Req),  % 1234 | undefined

%% Get Accept header
Accept = livery_req:accept(Req),  % <<"text/html, application/json">>

%% Get User-Agent header
UA = livery_req:user_agent(Req),

%% Check if WebSocket upgrade request
IsWS = livery_req:is_websocket_upgrade(Req),  % true | false

%% Check if SSL connection
IsSSL = livery_req:is_ssl(Req),  % true | false
```

---

## Response Patterns

### Simple Response

```erlang
handle(_Req, State) ->
    {reply, 200,
     [{<<"content-type">>, <<"text/plain">>}],
     <<"Hello, World!">>,
     State}.
```

### No Body Response

```erlang
handle(_Req, State) ->
    {reply, 204, [], State}.  % 204 No Content
```

### JSON Response

```erlang
handle(_Req, State) ->
    Data = #{message => <<"success">>, id => 123},
    Body = json:encode(Data),
    {reply, 200,
     [{<<"content-type">>, <<"application/json">>}],
     Body,
     State}.
```

### Redirect

```erlang
handle(_Req, State) ->
    {reply, 302,
     [{<<"location">>, <<"/new-location">>}],
     <<>>,
     State}.
```

### Error Response

```erlang
handle(_Req, State) ->
    {reply, 400,
     [{<<"content-type">>, <<"application/json">>}],
     <<"{\"error\":\"Bad Request\"}">>,
     State}.
```

---

## Helper Functions

The `livery_helpers` module provides convenient functions for common operations.

### Query String Parsing

```erlang
%% Parse query string to map
QS = livery_helpers:parse_qs(Req),
% #{<<"page">> => <<"1">>, <<"limit">> => <<"10">>}

%% Get single value
Page = livery_helpers:get_qs_value(<<"page">>, Req),  % <<"1">>
Page = livery_helpers:get_qs_value(<<"page">>, Req, <<"1">>),  % with default
```

### Form Parsing

```erlang
%% Parse URL-encoded form body
Form = livery_helpers:parse_form(Req),
Username = maps:get(<<"username">>, Form, <<>>),
Password = maps:get(<<"password">>, Form, <<>>),
```

### Multipart Form Data

```erlang
%% Parse multipart/form-data (file uploads)
case livery_helpers:parse_multipart(Req) of
    {ok, Parts} ->
        %% Each part is a map:
        %% #{name => <<"field_name">>, data => <<"content">>,
        %%   filename => <<"file.txt">>,      % optional
        %%   content_type => <<"text/plain">> % optional
        %% }
        handle_parts(Parts);
    {error, no_boundary} ->
        %% Not a multipart request
        error
end.
```

### JSON Helpers

```erlang
%% Parse JSON body
case livery_helpers:json_body(Req) of
    {ok, Data} ->
        %% Data is decoded JSON (map, list, etc.)
        process(Data);
    {error, no_body} ->
        error;
    {error, {invalid_json, _}} ->
        error
end.

%% Send JSON response
handle(_Req, State) ->
    Data = #{status => ok, items => [1, 2, 3]},
    livery_helpers:reply_json(200, Data, State).

%% With extra headers
handle(_Req, State) ->
    Data = #{created => true},
    livery_helpers:reply_json(201, Data, [{<<"x-request-id">>, <<"abc123">>}], State).
```

### Response Helpers

```erlang
%% Plain text response
livery_helpers:reply_text(200, <<"Hello">>, State)

%% HTML response
livery_helpers:reply_html(200, <<"<h1>Hello</h1>">>, State)

%% Serve a file
livery_helpers:reply_file(200, "/path/to/file.html", State)

%% Redirects
livery_helpers:reply_redirect(<<"/new-location">>, State)  % 302
livery_helpers:reply_redirect(301, <<"/permanent">>, State)  % 301

%% Error responses
livery_helpers:reply_not_found(State)                      % 404
livery_helpers:reply_bad_request(<<"Invalid input">>, State)  % 400
livery_helpers:reply_internal_error(<<"Server error">>, State) % 500
```

### Cookie Helpers

```erlang
%% Get cookie from request
SessionId = livery_helpers:get_cookie(<<"session">>, Req),
SessionId = livery_helpers:get_cookie(<<"session">>, Req, <<"default">>),

%% Set cookie in response
{HeaderName, HeaderValue} = livery_helpers:set_cookie(
    <<"session">>,
    <<"abc123">>,
    #{
        path => <<"/">>,
        max_age => 3600,        % 1 hour
        secure => true,
        http_only => true,
        same_site => strict     % strict | lax | none
    }
),
%% Add to response headers

%% Delete cookie
DeleteHeader = livery_helpers:delete_cookie(<<"session">>),
```

### Content Negotiation

```erlang
%% Check if client accepts content type
case livery_helpers:accepts_json(Req) of
    true -> send_json();
    false -> send_html()
end.

%% Check specific type
livery_helpers:accepts(<<"application/xml">>, Req)

%% Find preferred type
Preferred = livery_helpers:preferred_type(
    [<<"application/json">>, <<"text/html">>, <<"text/xml">>],
    Req
),
% Returns first matching type or undefined
```

### Path Bindings

When using the router (see [Routing](#routing)), path bindings are available:

```erlang
%% In handler, Opts contains bindings from router
handle(Req, #{handler_opts := Opts} = State) ->
    %% Get single binding
    UserId = livery_helpers:binding(<<"id">>, Opts),
    UserId = livery_helpers:binding(<<"id">>, Opts, <<"default">>),

    %% Get all bindings
    Bindings = livery_helpers:bindings(Opts),
    % #{<<"id">> => <<"123">>, <<"name">> => <<"john">>}
    ...
```

---

## Routing

Livery includes a fast prefix-tree router supporting:
- Static paths: `/users/list`
- Dynamic segments: `/users/:id`
- Wildcards: `/files/*path`
- Method-based routing

### Basic Router Setup

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
Router = livery_router:compile(Routes),

%% Match a request
case livery_router:match(Router, <<"GET">>, <<"/users/123">>) of
    {ok, Handler, Opts, Bindings} ->
        %% Handler = user_handler
        %% Bindings = #{<<"id">> => <<"123">>}
        Handler:handle(Req, Opts#{bindings => Bindings});
    {error, not_found} ->
        not_found
end.
```

### Using the Routing Handler

For convenience, use `livery_routing_handler` to automatically route requests:

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

### Dynamic Route Management

```erlang
%% Add route at runtime
Router2 = livery_router:add_route({get, "/new", new_handler, #{}}, Router),

%% Remove route
Router3 = livery_router:remove_route({get, "/old"}, Router2).
```

---

## Building REST APIs

### Complete REST API Example

Here's a complete example of a REST API for managing users:

```erlang
%% users_api.erl - Application entry point
-module(users_api).
-export([start/0]).

start() ->
    application:ensure_all_started(livery),

    Routes = [
        {get, "/api/users", users_list_handler, #{}},
        {get, "/api/users/:id", users_get_handler, #{}},
        {post, "/api/users", users_create_handler, #{}},
        {put, "/api/users/:id", users_update_handler, #{}},
        {delete, "/api/users/:id", users_delete_handler, #{}}
    ],
    Router = livery_router:compile(Routes),

    livery:start_listener(api_server, #{
        port => 8080,
        handler => livery_routing_handler,
        handler_opts => #{router => Router}
    }).
```

```erlang
%% users_list_handler.erl
-module(users_list_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, State) ->
    %% Parse pagination from query string
    Page = binary_to_integer(livery_helpers:get_qs_value(<<"page">>, Req, <<"1">>)),
    Limit = binary_to_integer(livery_helpers:get_qs_value(<<"limit">>, Req, <<"20">>)),

    %% Fetch users (replace with your data access)
    Users = fetch_users(Page, Limit),

    livery_helpers:reply_json(200, #{
        data => Users,
        page => Page,
        limit => Limit
    }, State).

fetch_users(_Page, _Limit) ->
    [#{id => 1, name => <<"Alice">>}, #{id => 2, name => <<"Bob">>}].
```

```erlang
%% users_get_handler.erl
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

fetch_user(<<"1">>) -> {ok, #{id => 1, name => <<"Alice">>}};
fetch_user(_) -> {error, not_found}.
```

```erlang
%% users_create_handler.erl
-module(users_create_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, State) ->
    case livery_helpers:json_body(Req) of
        {ok, #{<<"name">> := Name}} when is_binary(Name) ->
            %% Create user (replace with your logic)
            User = create_user(Name),
            livery_helpers:reply_json(201, User, State);
        {ok, _} ->
            livery_helpers:reply_json(400, #{error => <<"name is required">>}, State);
        {error, _} ->
            livery_helpers:reply_json(400, #{error => <<"Invalid JSON">>}, State)
    end.

create_user(Name) ->
    #{id => erlang:unique_integer([positive]), name => Name}.
```

```erlang
%% users_update_handler.erl
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
    {ok, maps:merge(#{id => 1, name => <<"Alice">>}, Updates)};
update_user(_, _) ->
    {error, not_found}.
```

```erlang
%% users_delete_handler.erl
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
delete_user(_) -> {error, not_found}.
```

### API Versioning

```erlang
Routes = [
    %% Version 1
    {get, "/api/v1/users", users_v1_handler, #{}},

    %% Version 2
    {get, "/api/v2/users", users_v2_handler, #{}},

    %% Catch-all API route
    {'_', "/api/*path", api_handler, #{}}
].
```

### Error Handling Pattern

```erlang
-module(api_base).
-export([handle_error/2]).

handle_error(validation_error, State) ->
    livery_helpers:reply_json(400, #{
        error => <<"validation_error">>,
        message => <<"Invalid request data">>
    }, State);
handle_error(not_found, State) ->
    livery_helpers:reply_json(404, #{
        error => <<"not_found">>,
        message => <<"Resource not found">>
    }, State);
handle_error(unauthorized, State) ->
    livery_helpers:reply_json(401, #{
        error => <<"unauthorized">>,
        message => <<"Authentication required">>
    }, State);
handle_error(forbidden, State) ->
    livery_helpers:reply_json(403, #{
        error => <<"forbidden">>,
        message => <<"Access denied">>
    }, State);
handle_error(_, State) ->
    livery_helpers:reply_json(500, #{
        error => <<"internal_error">>,
        message => <<"Something went wrong">>
    }, State).
```

---

## WebSocket Handlers

Livery supports WebSocket over HTTP/1.1, HTTP/2, and HTTP/3 (RFC 9220).

### Basic WebSocket Handler

```erlang
-module(ws_handler).
-behaviour(livery_handler).

-export([init/2, handle/2, websocket_handle/2, websocket_info/2]).

%% Accept WebSocket upgrade
init(Req, Opts) ->
    case livery_req:is_websocket_upgrade(Req) of
        true ->
            {websocket, Req, #{opts => Opts}};
        false ->
            {ok, Req, #{opts => Opts}}
    end.

%% Handle regular HTTP (if not upgraded)
handle(_Req, State) ->
    {reply, 400, [], <<"WebSocket upgrade required">>, State}.

%% Handle incoming WebSocket frames
websocket_handle({text, Text}, State) ->
    %% Echo text messages
    {reply, {text, Text}, State};

websocket_handle({binary, Data}, State) ->
    %% Echo binary data
    {reply, {binary, Data}, State};

websocket_handle({ping, Payload}, State) ->
    %% Respond to ping with pong
    {reply, {pong, Payload}, State};

websocket_handle({close, Code, Reason}, State) ->
    %% Client initiated close
    io:format("WebSocket closed: ~p ~p~n", [Code, Reason]),
    {stop, normal, State}.

%% Handle Erlang messages (e.g., from other processes)
websocket_info({broadcast, Message}, State) ->
    %% Send message to this WebSocket client
    {reply, {text, Message}, State};

websocket_info(_Info, State) ->
    {ok, State}.
```

### WebSocket Chat Example

```erlang
-module(chat_handler).
-behaviour(livery_handler).

-export([init/2, handle/2, websocket_handle/2, websocket_info/2, terminate/2]).

init(Req, Opts) ->
    case livery_req:is_websocket_upgrade(Req) of
        true ->
            %% Get username from query string
            Username = livery_helpers:get_qs_value(<<"username">>, Req, <<"anonymous">>),
            {websocket, Req, #{username => Username}};
        false ->
            {ok, Req, Opts}
    end.

handle(_Req, State) ->
    livery_helpers:reply_html(200, <<"<html>Chat client...</html>">>, State).

websocket_handle({text, Message}, #{username := Username} = State) ->
    %% Broadcast to all connected clients
    Payload = json:encode(#{
        type => <<"message">>,
        username => Username,
        text => Message,
        timestamp => erlang:system_time(millisecond)
    }),

    %% Get all connected clients and send message
    pg:get_members(chat_room) -- [self()]
        |> lists:foreach(fun(Pid) -> Pid ! {chat_message, Payload} end),

    %% Also send to self (confirmation)
    {reply, {text, Payload}, State};

websocket_handle({close, _, _}, State) ->
    {stop, normal, State}.

websocket_info({chat_message, Payload}, State) ->
    {reply, {text, Payload}, State};

websocket_info(_, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    pg:leave(chat_room, self()),
    ok.
```

### WebSocket Frame Types

```erlang
%% Incoming frames (from client)
{text, Binary}           %% UTF-8 text
{binary, Binary}         %% Binary data
{ping, Payload}          %% Ping frame
{pong, Payload}          %% Pong frame (usually ignored)
{close, Code, Reason}    %% Close frame

%% Outgoing frames (to client)
{text, Binary}           %% Send text
{binary, Binary}         %% Send binary
{ping, Payload}          %% Send ping
{pong, Payload}          %% Send pong
{close, Code, Reason}    %% Initiate close
```

### WebSocket Return Values

```erlang
{ok, State}              %% Continue without sending
{reply, Frame, State}    %% Send frame and continue
{stop, Reason, State}    %% Close connection
```

---

## Streaming Responses

For large responses or real-time data, use streaming:

### Basic Streaming

```erlang
handle(_Req, State) ->
    StreamFun = fun(Send) ->
        Send(<<"First chunk\n">>),
        Send(<<"Second chunk\n">>),
        Send(<<"Third chunk\n">>),
        Send(done)
    end,
    {stream, 200,
     [{<<"content-type">>, <<"text/plain">>}],
     StreamFun,
     State}.
```

### Server-Sent Events (SSE)

```erlang
-module(sse_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(_Req, State) ->
    StreamFun = fun(Send) ->
        %% Send events
        sse_loop(Send, 0)
    end,
    {stream, 200,
     [{<<"content-type">>, <<"text/event-stream">>},
      {<<"cache-control">>, <<"no-cache">>}],
     StreamFun,
     State}.

sse_loop(Send, Count) when Count < 10 ->
    Event = io_lib:format("data: ~p~n~n", [#{count => Count}]),
    Send(iolist_to_binary(Event)),
    timer:sleep(1000),
    sse_loop(Send, Count + 1);
sse_loop(Send, _) ->
    Send(done).
```

### Streaming with Trailers

```erlang
handle(_Req, State) ->
    StreamFun = fun(Send) ->
        Hash = crypto:hash_init(sha256),
        Hash1 = send_chunks(Send, Hash),
        Digest = crypto:hash_final(Hash1),
        Send({done, [{<<"x-content-sha256">>, base16:encode(Digest)}]})
    end,
    {stream, 200,
     [{<<"content-type">>, <<"application/octet-stream">>},
      {<<"trailer">>, <<"x-content-sha256">>}],
     StreamFun,
     State}.

send_chunks(Send, Hash) ->
    %% Send data chunks and update hash
    Chunk = get_next_chunk(),
    case Chunk of
        eof -> Hash;
        Data ->
            Send(Data),
            send_chunks(Send, crypto:hash_update(Hash, Data))
    end.
```

---

## Middleware

Middleware allows you to intercept and transform requests/responses.

### Defining Middleware

```erlang
-module(logging_middleware).
-export([before_request/2, after_response/4]).

%% Called before handler
before_request(Req, State) ->
    Start = erlang:monotonic_time(),
    {ok, Req, State#{start_time => Start}}.

%% Called after handler response
after_response(Req, Status, Headers, #{start_time := Start} = State) ->
    Duration = erlang:monotonic_time() - Start,
    Method = livery_req:method(Req),
    Path = livery_req:path(Req),
    io:format("~s ~s -> ~p (~p ms)~n",
              [Method, Path, Status, erlang:convert_time_unit(Duration, native, millisecond)]),
    {ok, Status, Headers, State}.
```

### Middleware Chain

```erlang
%% Compile middleware chain
Chain = livery_middleware:compile([
    {logging_middleware, #{}},
    {auth_middleware, #{secret => <<"my-secret">>}},
    {cors_middleware, #{origins => [<<"https://example.com">>]}}
]).

%% Use in handler
handle(Req, State) ->
    case livery_middleware:run(Chain, Req, State) of
        {ok, Req2, State2} ->
            %% Proceed with handling
            do_handle(Req2, State2);
        {stop, Status, Headers, Body, State2} ->
            %% Middleware short-circuited
            {reply, Status, Headers, Body, State2}
    end.
```

### Common Middleware Examples

#### CORS Middleware

```erlang
-module(cors_middleware).
-export([before_request/2, after_response/4]).

before_request(Req, State) ->
    case livery_req:method(Req) of
        <<"OPTIONS">> ->
            %% Preflight request
            Headers = cors_headers(),
            {stop, 204, Headers, <<>>, State};
        _ ->
            {ok, Req, State}
    end.

after_response(_Req, Status, Headers, State) ->
    {ok, Status, cors_headers() ++ Headers, State}.

cors_headers() ->
    [
        {<<"access-control-allow-origin">>, <<"*">>},
        {<<"access-control-allow-methods">>, <<"GET, POST, PUT, DELETE, OPTIONS">>},
        {<<"access-control-allow-headers">>, <<"Content-Type, Authorization">>}
    ].
```

#### Auth Middleware

```erlang
-module(auth_middleware).
-export([before_request/2]).

before_request(Req, #{secret := Secret} = State) ->
    case livery_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> ->
            case verify_token(Token, Secret) of
                {ok, UserId} ->
                    {ok, Req, State#{user_id => UserId}};
                error ->
                    {stop, 401, [], <<"Invalid token">>, State}
            end;
        _ ->
            {stop, 401, [], <<"Authorization required">>, State}
    end.

verify_token(_Token, _Secret) ->
    %% Implement JWT verification
    {ok, <<"user123">>}.
```

---

## Starting Servers

### Basic HTTP Server

```erlang
livery:start_listener(my_http, #{
    port => 8080,
    handler => my_handler,
    handler_opts => #{}
}).
```

### With Custom Options

```erlang
livery:start_listener(my_http, #{
    port => 8080,
    handler => my_handler,
    handler_opts => #{db_pool => my_db},

    %% Number of acceptor processes
    num_acceptors => erlang:system_info(schedulers),

    %% TCP options
    tcp_opts => [
        {backlog, 1024},
        {nodelay, true}
    ]
}).
```

### Multiple Listeners

```erlang
%% HTTP on port 80
livery:start_listener(http_80, #{port => 80, handler => my_handler}),

%% HTTPS on port 443
livery:start_listener(https_443, #{
    port => 443,
    handler => my_handler,
    ssl => true,
    ssl_opts => [
        {certfile, "/path/to/cert.pem"},
        {keyfile, "/path/to/key.pem"}
    ]
}),

%% Internal API on different port
livery:start_listener(internal_api, #{port => 9090, handler => internal_handler}).
```

### Stopping Listeners

```erlang
%% Graceful shutdown (wait for connections)
livery:stop_listener(my_http).

%% Immediate shutdown
livery:stop_listener(my_http, #{grace_period => 0}).

%% Shutdown all listeners
livery:shutdown_all().
```

---

## HTTPS & HTTP/3 Configuration

### HTTPS Setup

```erlang
livery:start_listener(my_https, #{
    port => 443,
    handler => my_handler,
    ssl => true,
    ssl_opts => [
        {certfile, "/path/to/fullchain.pem"},
        {keyfile, "/path/to/privkey.pem"},
        {cacertfile, "/path/to/chain.pem"},

        %% TLS versions
        {versions, ['tlsv1.3', 'tlsv1.2']},

        %% Cipher suites
        {ciphers, [
            "TLS_AES_256_GCM_SHA384",
            "TLS_CHACHA20_POLY1305_SHA256",
            "TLS_AES_128_GCM_SHA256"
        ]},

        %% ALPN for HTTP/2
        {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}
    ]
}).
```

### HTTP/2 Support

HTTP/2 is automatically negotiated via ALPN when using HTTPS:

```erlang
livery:start_listener(my_h2, #{
    port => 443,
    handler => my_handler,
    ssl => true,
    ssl_opts => [
        {certfile, "cert.pem"},
        {keyfile, "key.pem"},
        %% Enable HTTP/2
        {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}
    ],
    %% HTTP/2 specific settings
    h2_opts => #{
        max_concurrent_streams => 100,
        initial_window_size => 65535
    }
}).
```

### HTTP/3 (QUIC) Setup

```erlang
livery:start_listener(my_h3, #{
    port => 443,
    handler => my_handler,
    protocol => http3,
    quic_opts => [
        {certfile, "cert.pem"},
        {keyfile, "key.pem"}
    ],
    h3_opts => #{
        max_concurrent_streams => 100
    }
}).
```

---

## Telemetry & Observability

Livery emits telemetry events for monitoring and observability.

### Available Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[livery, connection, start]` | `system_time` | `peer`, `protocol` |
| `[livery, connection, stop]` | `duration` | `peer`, `protocol`, `reason` |
| `[livery, request, start]` | `system_time` | `method`, `path`, `peer` |
| `[livery, request, stop]` | `duration` | `method`, `path`, `status`, `body_size` |
| `[livery, request, exception]` | `duration` | `kind`, `reason`, `stacktrace` |
| `[livery, websocket, upgrade]` | `system_time` | `peer`, `protocol` |
| `[livery, websocket, frame, in]` | `size` | `type`, `peer` |
| `[livery, websocket, frame, out]` | `size` | `type`, `peer` |

### Attaching Handlers

```erlang
%% Attach telemetry handler
telemetry:attach_many(
    my_handler,
    [
        [livery, request, start],
        [livery, request, stop]
    ],
    fun handle_event/4,
    #{}
).

handle_event([livery, request, stop], Measurements, Metadata, _Config) ->
    #{duration := Duration} = Measurements,
    #{method := Method, path := Path, status := Status} = Metadata,
    io:format("~s ~s -> ~p (~p us)~n",
              [Method, Path, Status, erlang:convert_time_unit(Duration, native, microsecond)]).
```

### Integration with Prometheus

```erlang
%% Using prometheus_telemetry
prometheus_telemetry:register([
    {histogram, [livery, request, duration_seconds], #{
        event_name => [livery, request, stop],
        measurement => duration,
        unit => second,
        labels => [method, status]
    }},
    {counter, [livery, request, total], #{
        event_name => [livery, request, stop],
        labels => [method, status]
    }}
]).
```

---

## Configuration Reference

### Listener Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `port` | integer | required | TCP port to listen on |
| `handler` | module | required | Handler module |
| `handler_opts` | term | `#{}` | Options passed to handler |
| `num_acceptors` | integer | schedulers | Number of acceptor processes |
| `ssl` | boolean | `false` | Enable SSL/TLS |
| `ssl_opts` | list | `[]` | SSL options (see ssl module) |
| `protocol` | atom | `http` | Protocol: `http`, `http2`, `http3` |
| `tcp_opts` | list | `[]` | TCP socket options |
| `h2_opts` | map | `#{}` | HTTP/2 settings |
| `h3_opts` | map | `#{}` | HTTP/3 settings |
| `quic_opts` | list | `[]` | QUIC options for HTTP/3 |

### TCP Options

Common TCP options:

```erlang
tcp_opts => [
    {backlog, 1024},      %% Connection backlog
    {nodelay, true},      %% Disable Nagle's algorithm
    {sndbuf, 65536},      %% Send buffer size
    {recbuf, 65536},      %% Receive buffer size
    {keepalive, true}     %% Enable keepalive
]
```

### HTTP/2 Settings

```erlang
h2_opts => #{
    max_concurrent_streams => 100,
    initial_window_size => 65535,
    max_frame_size => 16384,
    max_header_list_size => 8192
}
```

### HTTP/3 Settings

```erlang
h3_opts => #{
    max_concurrent_streams => 100,
    max_header_list_size => 8192,
    qpack_max_table_capacity => 4096,
    qpack_blocked_streams => 100
}
```

### Request Limits

Default limits (defined in `livery.hrl`):

| Limit | Default | Description |
|-------|---------|-------------|
| `MAX_METHOD_SIZE` | 16 | Max HTTP method length |
| `MAX_URI_SIZE` | 8192 | Max URI length |
| `MAX_HEADER_NAME_SIZE` | 256 | Max header name length |
| `MAX_HEADER_VALUE_SIZE` | 8192 | Max header value length |
| `MAX_HEADERS` | 100 | Max number of headers |
| `MAX_CHUNK_SIZE` | 1MB | Max chunked encoding chunk |
| `MAX_BODY_SIZE` | 8MB | Max request body size |

---

## Example Applications

### Minimal API Server

```erlang
-module(minimal_api).
-behaviour(livery_handler).
-export([start/0, init/2, handle/2]).

start() ->
    application:ensure_all_started(livery),
    livery:start_listener(api, #{port => 8080, handler => ?MODULE}).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, State) ->
    case {livery_req:method(Req), livery_req:path(Req)} of
        {<<"GET">>, <<"/">>} ->
            livery_helpers:reply_json(200, #{status => ok}, State);
        {<<"GET">>, <<"/health">>} ->
            livery_helpers:reply_text(200, <<"OK">>, State);
        _ ->
            livery_helpers:reply_not_found(State)
    end.
```

### File Server

```erlang
-module(file_server).
-behaviour(livery_handler).
-export([start/0, init/2, handle/2]).

start() ->
    application:ensure_all_started(livery),
    livery:start_listener(files, #{
        port => 8080,
        handler => ?MODULE,
        handler_opts => #{root => "/var/www/html"}
    }).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, #{root := Root} = State) ->
    Path = livery_req:path(Req),
    SafePath = sanitize_path(Path),
    FilePath = filename:join(Root, SafePath),

    case file:read_file(FilePath) of
        {ok, Content} ->
            ContentType = guess_type(FilePath),
            {reply, 200, [{<<"content-type">>, ContentType}], Content, State};
        {error, enoent} ->
            livery_helpers:reply_not_found(State);
        {error, _} ->
            livery_helpers:reply_internal_error(<<"File read error">>, State)
    end.

sanitize_path(<<"/">>)  -> <<"index.html">>;
sanitize_path(<<"/", Path/binary>>) -> binary:replace(Path, <<"..">>, <<>>, [global]);
sanitize_path(Path) -> Path.

guess_type(Path) ->
    case filename:extension(Path) of
        <<".html">> -> <<"text/html">>;
        <<".css">> -> <<"text/css">>;
        <<".js">> -> <<"application/javascript">>;
        <<".json">> -> <<"application/json">>;
        <<".png">> -> <<"image/png">>;
        <<".jpg">> -> <<"image/jpeg">>;
        _ -> <<"application/octet-stream">>
    end.
```

---

## Additional Resources

- [API Documentation](api.html) - Generated from source code
- [GitHub Repository](https://github.com/benoitc/livery) - Source code and issues
- [Erlang OTP Documentation](https://www.erlang.org/doc/) - General Erlang reference

---

*Livery HTTP Server - Fast, simple, and powerful.*
