# How to log every request

## Problem

You want the classic access log: one tidy, structured line per
completed request, with the method, the path, the status, how long it
took, and the request id to tie it all together.

## Solution

Two middlewares, and you are done:

```erlang
Stack = [
    {livery_request_id, undefined},
    {livery_access_log, #{}}
    %% ... handler
].
```

`livery_access_log` emits one entry through `logger:log/2` once the
handler returns. Here is what each line carries:

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

The default level is `info`. Override it in the state:

```erlang
{livery_access_log, #{level => notice}}
```

A common surprise: if your `logger` primary level sits at `notice`
(the OTP default), `info` lines are dropped before they reach a
handler. So either log at `notice` or higher, or raise the primary
level while you develop:

```erlang
logger:set_primary_config(level, info).
```

## Read the entries

These are plain `logger` events, so any `logger` handler picks them
up. To route them somewhere of your own, add a handler with a filter
that keeps only the access lines:

```erlang
logger:add_handler(my_access, my_handler,
    #{level => info,
      filters => [{access_only,
        {fun (#{msg := {report, #{msg := "livery_access"}}}, _) -> log;
             (_, _) -> stop
         end, []}}]}).
```

## Ordering

Order matters in two small ways. Place `livery_access_log` after
`livery_request_id`, so the `request_id` you log is the same one the
client receives. And place it inside your error wrapper, so the 500s
get logged too instead of vanishing with the crash.

```erlang
Stack = [
    {livery_request_id, undefined},
    livery_middleware:wrap(fun my_app:errors_to_resp/3),
    {livery_access_log, #{}},
    %% ... business middlewares and handler
].
```

## Correlate access logs with traces

If you also run the `livery_instrument_trace` middleware, you can
make your access logs and your traces point at each other. Install
the `instrument` logger filter once at boot:

```erlang
ok = livery_instrument_trace:install_logger().
```

From then on, every `logger` event emitted while a span is active is
enriched with that span's `trace_id`, `span_id`, and `trace_flags` in
its metadata. Stack the trace middleware *outside* `livery_access_log`
and each access-log line then carries the same ids as the request's
span:

```erlang
Stack = [
    {livery_request_id, undefined},
    {livery_instrument_trace, #{}},
    {livery_access_log, #{}},
    %% ... handler
].
```

Better still, any `logger` call your handler makes during the request
inherits the same ids, so your application logs, your access logs,
and the trace in your backend all line up.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`, `livery_instrument_trace`
- Recipe: [Propagate request IDs](propagate-request-ids.md)
