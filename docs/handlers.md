# Handlers

Handlers are the core building blocks of a Livery application. They implement the `livery_handler` behaviour to process HTTP requests.

## The livery_handler Behaviour

```erlang
-module(my_handler).
-behaviour(livery_handler).

-export([init/2, handle/2, terminate/2]).

init(Req, Opts) ->
    {ok, Req, #{opts => Opts}}.

handle(Req, State) ->
    Method = livery_req:method(Req),
    Path = livery_req:path(Req),
    handle_request(Method, Path, Req, State).

terminate(_Reason, _State) ->
    ok.

handle_request(<<"GET">>, <<"/health">>, _Req, State) ->
    {reply, 200, [], <<"OK">>, State};
handle_request(_, _, _Req, State) ->
    {reply, 404, [], <<"Not Found">>, State}.
```

## Callbacks

| Callback | Required | Description |
|----------|----------|-------------|
| `init/2` | Yes | Initialize state, return `{ok, Req, State}` |
| `handle/2` | Yes | Process request, return response tuple |
| `terminate/2` | No | Cleanup when connection closes |
| `websocket_handle/2` | No | Handle WebSocket frames |
| `websocket_info/2` | No | Handle Erlang messages during WebSocket |

## init/2

The `init/2` callback is called when a new request arrives. It receives the request record and options from the listener configuration.

**Parameters:**
- `Req` - The request record (`#livery_req{}`)
- `Opts` - Options from `handler_opts` in listener config

**Return Values:**

```erlang
%% Proceed with HTTP handling
{ok, Req, State}

%% Accept WebSocket upgrade
{websocket, Req, State}

%% Abort request
{error, Reason}
```

**Example:**

```erlang
init(Req, Opts) ->
    %% Access handler_opts from listener config
    DbPool = maps:get(db_pool, Opts, default_pool),
    {ok, Req, #{db_pool => DbPool}}.
```

## handle/2

The `handle/2` callback processes the request and returns a response.

**Parameters:**
- `Req` - The request record
- `State` - State returned from `init/2`

**Return Values:**

```erlang
%% Complete response with body
{reply, Status, Headers, Body, State}

%% Response with no body (e.g., 204)
{reply, Status, Headers, State}

%% Streaming response
{stream, Status, Headers, StreamFun, State}

%% Error response
{error, Reason, State}
```

**Example:**

```erlang
handle(Req, State) ->
    case livery_req:method(Req) of
        <<"GET">> ->
            {reply, 200, [{<<"content-type">>, <<"text/plain">>}], <<"Hello">>, State};
        <<"POST">> ->
            Body = livery_req:body(Req),
            {reply, 201, [{<<"content-type">>, <<"text/plain">>}], Body, State};
        _ ->
            {reply, 405, [], <<"Method Not Allowed">>, State}
    end.
```

## terminate/2

The `terminate/2` callback is called when the connection closes. Use it for cleanup.

**Parameters:**
- `Reason` - `normal` or `{error, term()}`
- `State` - Final handler state

**Example:**

```erlang
terminate(Reason, #{db_conn := Conn}) ->
    %% Close database connection
    db:close(Conn),
    case Reason of
        normal -> ok;
        {error, Why} ->
            error_logger:warning_msg("Connection closed: ~p~n", [Why])
    end,
    ok.
```

## Handler State Management

The state is a term of your choice (commonly a map) that persists across callbacks:

```erlang
init(Req, Opts) ->
    %% Initialize state
    {ok, Req, #{
        user => undefined,
        start_time => erlang:monotonic_time()
    }}.

handle(Req, State) ->
    %% Update state
    NewState = State#{user => <<"anonymous">>},
    {reply, 200, [], <<"OK">>, NewState}.

terminate(_Reason, #{start_time := Start}) ->
    Duration = erlang:monotonic_time() - Start,
    io:format("Request took ~p ms~n",
              [erlang:convert_time_unit(Duration, native, millisecond)]),
    ok.
```

## Error Handling

Handle errors gracefully in your handler:

```erlang
handle(Req, State) ->
    try
        process_request(Req, State)
    catch
        error:badarg ->
            {reply, 400, [], <<"Bad Request">>, State};
        _:Reason ->
            error_logger:error_msg("Handler error: ~p~n", [Reason]),
            {reply, 500, [], <<"Internal Server Error">>, State}
    end.
```

## Multiple Handlers

You can have different handlers for different purposes:

```erlang
%% Start multiple listeners with different handlers
livery:start_listener(public_api, #{
    port => 8080,
    handler => public_handler
}),

livery:start_listener(admin_api, #{
    port => 9090,
    handler => admin_handler
}).
```

Or use routing to dispatch to different handlers (see [Routing](routing.md)).
