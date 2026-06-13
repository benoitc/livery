# How to log every request

`livery_access_log` is a middleware that emits one structured log entry
per completed request, with method, path, status, duration, and request
id. You need it when you want a single audit line for each request that
reaches your service.

## Add it to the stack

```erlang
Stack = [
    {livery_request_id, undefined},
    {livery_access_log, #{}}
    %% ... handler
].
```

`livery_access_log` emits one entry through `logger:log/2` after the
handler returns. Fields:

| Key | Value |
|---|---|
| `msg` | `"livery_access"` |
| `protocol` | `h1` / `h2` / `h3` |
| `method` | request method, binary |
| `path` | request path, binary |
| `status` | response status code |
| `duration_us` | request duration in microseconds |
| `request_id` | id from `livery_request_id`, or `<<>>` |

## Configure the level

The default level is `info`. Override it in state:

```erlang
{livery_access_log, #{level => notice}}
```

If your `logger` primary level is at `notice` (the OTP default), use
`notice` or higher, or raise the primary level for development:

```erlang
logger:set_primary_config(level, info).
```

## Read the entries

This is a standard `logger` handler. To send entries to a custom
destination, add a handler:

```erlang
logger:add_handler(my_access, my_handler,
    #{level => info,
      filters => [{access_only,
        {fun (#{msg := {report, #{msg := "livery_access"}}}, _) -> log;
             (_, _) -> stop
         end, []}}]}).
```

## Order the stack

Place `livery_access_log` after `livery_request_id` so the recorded
`request_id` is the one the client also receives. Place it inside an
error wrapper so 500s are still logged.

```erlang
Stack = [
    {livery_request_id, undefined},
    livery_middleware:wrap(fun my_app:errors_to_resp/3),
    {livery_access_log, #{}},
    %% ... business middlewares and handler
].
```

## Correlate access logs with traces

If you also run the `livery_instrument_trace` middleware, install the
`instrument` logger filter once at boot:

```erlang
ok = livery_instrument_trace:install_logger().
```

The filter enriches every `logger` event emitted while a span is active
with the span's `trace_id`, `span_id`, and `trace_flags` in the event
metadata. Stack the trace middleware *outside* `livery_access_log` and
each access-log line carries the same ids as the request's span:

```erlang
Stack = [
    {livery_request_id, undefined},
    {livery_instrument_trace, #{}},
    {livery_access_log, #{}},
    %% ... handler
].
```

Any `logger` call your handler makes during the request inherits the
same ids, so application logs and access logs line up with the trace in
your backend.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`, `livery_instrument_trace`
- Guide: [Propagate request IDs](propagate-request-ids.md)
