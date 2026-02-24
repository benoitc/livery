# Hooks

Livery provides a hook-based event system for observability and instrumentation. Hooks are simple callbacks that are invoked when specific events occur.

## Available Events

### Connection Events

#### `connection_start`
Emitted when a connection is accepted.

| Data Key | Type | Description |
|----------|------|-------------|
| `listener` | atom | Listener name |
| `peer` | `{ip(), port()}` | Client address |
| `transport` | `tcp \| ssl` | Transport type |
| `system_time` | integer | System time when connection started |

#### `connection_stop`
Emitted when a connection closes.

| Data Key | Type | Description |
|----------|------|-------------|
| `listener` | atom | Listener name |
| `peer` | `{ip(), port()}` | Client address |
| `reason` | term | Close reason |
| `duration` | integer | Connection duration (native time units) |

### Request Events

#### `request_start`
Emitted when a request is received.

| Data Key | Type | Description |
|----------|------|-------------|
| `method` | binary | HTTP method |
| `path` | binary | Request path |
| `protocol` | `h1 \| h2 \| h3` | HTTP protocol version |
| `system_time` | integer | System time when request started |

#### `request_stop`
Emitted when a request completes.

| Data Key | Type | Description |
|----------|------|-------------|
| `method` | binary | HTTP method |
| `path` | binary | Request path |
| `status` | integer | HTTP status code |
| `duration` | integer | Request duration (native time units) |
| `resp_body_size` | integer | Response body size in bytes |

#### `request_exception`
Emitted when a request fails with an exception.

| Data Key | Type | Description |
|----------|------|-------------|
| `method` | binary | HTTP method |
| `path` | binary | Request path |
| `kind` | `error \| exit \| throw` | Exception kind |
| `reason` | term | Exception reason |
| `stacktrace` | list | Stack trace |
| `duration` | integer | Duration until exception |

### WebSocket Events

#### `websocket_upgrade`
Emitted when a WebSocket upgrade is accepted.

| Data Key | Type | Description |
|----------|------|-------------|
| `path` | binary | WebSocket path |
| `system_time` | integer | System time of upgrade |

#### `websocket_frame`
Emitted when a WebSocket frame is sent or received.

| Data Key | Type | Description |
|----------|------|-------------|
| `direction` | `in \| out` | Frame direction |
| `opcode` | atom | Frame type (`text`, `binary`, `ping`, `pong`, `close`) |
| `size` | integer | Frame size in bytes |

## Adding Hooks

```erlang
%% Add a hook for an event
Ref = livery_hooks:add(request_stop, fun(Data) ->
    #{method := Method, path := Path, status := Status, duration := Duration} = Data,
    DurationMs = erlang:convert_time_unit(Duration, native, millisecond),
    io:format("~s ~s -> ~p (~p ms)~n", [Method, Path, Status, DurationMs])
end).

%% Add a hook with a tag for identification
Ref = livery_hooks:add(request_stop, MyFun, my_logger).

%% Multiple hooks for the same event
livery_hooks:add(request_stop, fun log_request/1, logger).
livery_hooks:add(request_stop, fun update_metrics/1, metrics).
```

## Removing Hooks

```erlang
%% Remove a specific hook by reference
ok = livery_hooks:delete(request_stop, Ref).
```

## Listing Hooks

```erlang
%% List all hooks for an event
Hooks = livery_hooks:list(request_stop).
%% Returns: [{Ref1, logger}, {Ref2, metrics}]
```

## Example: Request Logging

```erlang
-module(request_logger).
-export([setup/0]).

setup() ->
    livery_hooks:add(request_stop, fun(Data) ->
        #{method := Method, path := Path, status := Status, duration := Duration} = Data,
        DurationUs = erlang:convert_time_unit(Duration, native, microsecond),
        logger:info(#{
            event => request_completed,
            method => Method,
            path => Path,
            status => Status,
            duration_us => DurationUs
        })
    end, request_logger).
```

## Example: Prometheus Metrics

```erlang
-module(prometheus_hooks).
-export([setup/0]).

setup() ->
    %% Declare metrics
    prometheus_counter:new([
        {name, http_requests_total},
        {labels, [method, status_class]},
        {help, "Total HTTP requests"}
    ]),
    prometheus_histogram:new([
        {name, http_request_duration_seconds},
        {labels, [method]},
        {buckets, [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5]},
        {help, "HTTP request duration"}
    ]),

    %% Add hooks
    livery_hooks:add(request_stop, fun(Data) ->
        #{method := Method, status := Status, duration := Duration} = Data,
        StatusClass = integer_to_list(Status div 100) ++ "xx",
        DurationSecs = Duration / erlang:convert_time_unit(1, second, native),

        prometheus_counter:inc(http_requests_total, [Method, StatusClass]),
        prometheus_histogram:observe(http_request_duration_seconds, [Method], DurationSecs)
    end, prometheus_metrics).
```

## Example: Connection Tracking

```erlang
-module(connection_tracker).
-export([setup/0, active_connections/0]).

setup() ->
    ets:new(active_connections, [named_table, public, set]),

    livery_hooks:add(connection_start, fun(#{peer := Peer}) ->
        ets:insert(active_connections, {Peer, erlang:monotonic_time()})
    end, conn_tracker),

    livery_hooks:add(connection_stop, fun(#{peer := Peer}) ->
        ets:delete(active_connections, Peer)
    end, conn_tracker).

active_connections() ->
    ets:info(active_connections, size).
```

## Example: Custom Metrics Module

```erlang
-module(my_metrics).
-export([setup/0]).

setup() ->
    %% Initialize ETS table for metrics
    ets:new(metrics, [named_table, public, {write_concurrency, true}]),

    %% Add hooks
    livery_hooks:add(request_stop, fun(#{status := Status, duration := Duration}) ->
        %% Increment request counter
        Key = {request_count, Status div 100},
        ets:update_counter(metrics, Key, 1, {Key, 0}),

        %% Update duration histogram
        DurationMs = erlang:convert_time_unit(Duration, native, millisecond),
        Bucket = duration_bucket(DurationMs),
        ets:update_counter(metrics, {duration_bucket, Bucket}, 1, {{duration_bucket, Bucket}, 0})
    end, metrics),

    livery_hooks:add(connection_start, fun(_) ->
        ets:update_counter(metrics, active_connections, 1, {active_connections, 0})
    end, metrics),

    livery_hooks:add(connection_stop, fun(_) ->
        ets:update_counter(metrics, active_connections, -1, {active_connections, 0})
    end, metrics).

duration_bucket(Ms) when Ms < 1 -> '1ms';
duration_bucket(Ms) when Ms < 10 -> '10ms';
duration_bucket(Ms) when Ms < 100 -> '100ms';
duration_bucket(Ms) when Ms < 1000 -> '1s';
duration_bucket(_) -> 'over_1s'.
```

## Error Handling

Hooks are called synchronously. If a hook raises an exception, it is caught and logged, but does not affect other hooks or the request processing:

```erlang
%% This failing hook won't crash the server
livery_hooks:add(request_stop, fun(_) ->
    error(intentional_error)
end).

%% This hook will still be called
livery_hooks:add(request_stop, fun(Data) ->
    log_request(Data)
end).
```

## Custom Events

You can use the hook system for your own events:

```erlang
%% In your application code
livery_hooks:run(my_custom_event, #{key => value, timestamp => erlang:system_time()}).

%% Elsewhere, register a handler
livery_hooks:add(my_custom_event, fun handle_custom_event/1).
```

## Performance Considerations

- Hooks are called synchronously in the request/connection process
- Keep hook functions fast to avoid impacting request latency
- For expensive operations, consider spawning a process or using a queue
- Use the tag parameter to organize and identify hooks easily
