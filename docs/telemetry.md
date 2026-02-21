# Telemetry

Livery emits telemetry events for monitoring and observability using the standard Erlang telemetry library.

## Available Events

### Connection Events

#### `[livery, connection, start]`
Emitted when a connection is accepted.

| Measurements | Type | Description |
|-------------|------|-------------|
| `system_time` | integer | System time when connection started |

| Metadata | Type | Description |
|----------|------|-------------|
| `listener` | atom | Listener name |
| `peer` | `{ip(), port()}` | Client address |
| `transport` | `tcp \| ssl` | Transport type |

#### `[livery, connection, stop]`
Emitted when a connection closes.

| Measurements | Type | Description |
|-------------|------|-------------|
| `duration` | integer | Connection duration (native time units) |

| Metadata | Type | Description |
|----------|------|-------------|
| `listener` | atom | Listener name |
| `peer` | `{ip(), port()}` | Client address |
| `reason` | term | Close reason |

### Request Events

#### `[livery, request, start]`
Emitted when a request is received.

| Measurements | Type | Description |
|-------------|------|-------------|
| `system_time` | integer | System time when request started |

| Metadata | Type | Description |
|----------|------|-------------|
| `method` | binary | HTTP method |
| `path` | binary | Request path |
| `protocol` | `h1 \| h2 \| h3` | HTTP protocol version |

#### `[livery, request, stop]`
Emitted when a request completes.

| Measurements | Type | Description |
|-------------|------|-------------|
| `duration` | integer | Request duration (native time units) |
| `resp_body_size` | integer | Response body size in bytes |

| Metadata | Type | Description |
|----------|------|-------------|
| `method` | binary | HTTP method |
| `path` | binary | Request path |
| `status` | integer | HTTP status code |

#### `[livery, request, exception]`
Emitted when a request fails with an exception.

| Measurements | Type | Description |
|-------------|------|-------------|
| `duration` | integer | Duration until exception |

| Metadata | Type | Description |
|----------|------|-------------|
| `method` | binary | HTTP method |
| `path` | binary | Request path |
| `kind` | `error \| exit \| throw` | Exception kind |
| `reason` | term | Exception reason |
| `stacktrace` | list | Stack trace |

### WebSocket Events

#### `[livery, websocket, upgrade]`
Emitted when a WebSocket upgrade is accepted.

| Measurements | Type | Description |
|-------------|------|-------------|
| `system_time` | integer | System time of upgrade |

| Metadata | Type | Description |
|----------|------|-------------|
| `path` | binary | WebSocket path |

#### `[livery, websocket, frame]`
Emitted when a WebSocket frame is sent or received.

| Measurements | Type | Description |
|-------------|------|-------------|
| `size` | integer | Frame size in bytes |

| Metadata | Type | Description |
|----------|------|-------------|
| `direction` | `in \| out` | Frame direction |
| `opcode` | atom | Frame type |

## Attaching Handlers

```erlang
%% Attach to a single event
telemetry:attach(
    <<"my-handler">>,
    [livery, request, stop],
    fun handle_event/4,
    #{}
).

%% Attach to multiple events
telemetry:attach_many(
    <<"my-handler">>,
    [
        [livery, request, start],
        [livery, request, stop],
        [livery, request, exception]
    ],
    fun handle_event/4,
    #{}
).

handle_event([livery, request, stop], Measurements, Metadata, _Config) ->
    #{duration := Duration} = Measurements,
    #{method := Method, path := Path, status := Status} = Metadata,
    DurationMs = erlang:convert_time_unit(Duration, native, millisecond),
    io:format("~s ~s -> ~p (~p ms)~n", [Method, Path, Status, DurationMs]);

handle_event([livery, request, exception], _Measurements, Metadata, _Config) ->
    #{kind := Kind, reason := Reason} = Metadata,
    error_logger:error_msg("Request exception: ~p:~p~n", [Kind, Reason]);

handle_event(_, _, _, _) ->
    ok.
```

## Using Telemetry Spans

The `livery_telemetry` module provides a helper for wrapping operations:

```erlang
%% Execute a function with automatic start/stop events
Result = livery_telemetry:span([myapp, database, query], #{table => users}, fun() ->
    db:query("SELECT * FROM users")
end).

%% This emits:
%% [myapp, database, query, start] with system_time
%% [myapp, database, query, stop] with duration (on success)
%% [myapp, database, query, exception] with duration (on failure)
```

## Metrics Collection

### Example: Prometheus Integration

```erlang
%% Using prometheus_telemetry or similar library
prometheus_telemetry:register([
    %% Request duration histogram
    {histogram, [livery, request, duration_seconds], #{
        event_name => [livery, request, stop],
        measurement => duration,
        unit => second,
        labels => [method, status],
        buckets => [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5]
    }},

    %% Request counter
    {counter, [livery, request, total], #{
        event_name => [livery, request, stop],
        labels => [method, status]
    }},

    %% Active connections gauge
    {counter, [livery, connection, total], #{
        event_name => [livery, connection, start]
    }}
]).
```

### Example: Custom Metrics Module

```erlang
-module(my_metrics).
-export([setup/0, handle_event/4]).

setup() ->
    %% Initialize ETS table for metrics
    ets:new(metrics, [named_table, public, {write_concurrency, true}]),

    %% Attach handlers
    telemetry:attach_many(
        <<"my-metrics">>,
        [
            [livery, request, stop],
            [livery, connection, start],
            [livery, connection, stop]
        ],
        fun ?MODULE:handle_event/4,
        #{}
    ).

handle_event([livery, request, stop], #{duration := Duration}, #{status := Status}, _) ->
    %% Increment request counter
    Key = {request_count, Status div 100},  % Group by status class
    ets:update_counter(metrics, Key, 1, {Key, 0}),

    %% Update duration histogram (simplified)
    DurationMs = erlang:convert_time_unit(Duration, native, millisecond),
    Bucket = duration_bucket(DurationMs),
    ets:update_counter(metrics, {duration_bucket, Bucket}, 1, {{duration_bucket, Bucket}, 0});

handle_event([livery, connection, start], _, _, _) ->
    ets:update_counter(metrics, active_connections, 1, {active_connections, 0});

handle_event([livery, connection, stop], _, _, _) ->
    ets:update_counter(metrics, active_connections, -1, {active_connections, 0});

handle_event(_, _, _, _) ->
    ok.

duration_bucket(Ms) when Ms < 1 -> '1ms';
duration_bucket(Ms) when Ms < 10 -> '10ms';
duration_bucket(Ms) when Ms < 100 -> '100ms';
duration_bucket(Ms) when Ms < 1000 -> '1s';
duration_bucket(_) -> 'over_1s'.
```

## Logging Integration

```erlang
-module(request_logger).
-export([setup/0]).

setup() ->
    telemetry:attach(
        <<"request-logger">>,
        [livery, request, stop],
        fun(Event, Measurements, Metadata, _Config) ->
            #{duration := Duration, resp_body_size := BodySize} = Measurements,
            #{method := Method, path := Path, status := Status} = Metadata,
            DurationUs = erlang:convert_time_unit(Duration, native, microsecond),

            logger:info(#{
                event => request_completed,
                method => Method,
                path => Path,
                status => Status,
                duration_us => DurationUs,
                body_size => BodySize
            })
        end,
        #{}
    ).
```

## Emitting Custom Events

Use the module directly for custom instrumentation:

```erlang
%% Connection events
StartTime = livery_telemetry:connection_start(my_listener, #{peer => Peer}),
%% ... connection handling ...
livery_telemetry:connection_stop(StartTime, normal, #{peer => Peer}).

%% Request events
StartTime = livery_telemetry:request_start(Method, #{path => Path}),
%% ... request handling ...
livery_telemetry:request_stop(StartTime, Status, #{path => Path, resp_body_size => Size}).

%% Exception events
livery_telemetry:request_exception(StartTime, error, Reason, #{path => Path}).

%% WebSocket events
livery_telemetry:websocket_upgrade(#{path => Path}).
livery_telemetry:websocket_frame(in, text, ByteSize).
livery_telemetry:websocket_frame(out, binary, ByteSize).
```

## Disabling Telemetry

Telemetry events are only emitted if the telemetry application is loaded. If telemetry is not available, events are silently ignored.

To disable telemetry explicitly, simply don't start the telemetry application or don't attach any handlers.
