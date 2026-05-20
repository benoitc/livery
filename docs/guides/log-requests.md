# How to log every request

## Problem

You want one structured log entry per completed request with
method, path, status, duration, and request id.

## Solution

```erlang
Stack = [
    {livery_request_id, undefined},
    {livery_access_log, #{}}
    %% ... handler
].
```

`livery_access_log` emits one entry through `logger:log/2` after
the handler returns. Fields:

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

Default level is `info`. Override in state:

```erlang
{livery_access_log, #{level => notice}}
```

If your `logger` primary level is at `notice` (OTP default), use
`notice` or higher, or raise the primary level for development:

```erlang
logger:set_primary_config(level, info).
```

## Read the entries

Standard `logger` handler. To send entries to a custom destination,
add a handler:

```erlang
logger:add_handler(my_access, my_handler,
    #{level => info,
      filters => [{access_only,
        {fun (#{msg := {report, #{msg := "livery_access"}}}, _) -> log;
             (_, _) -> stop
         end, []}}]}).
```

## Ordering

Place `livery_access_log` after `livery_request_id` so the
recorded `request_id` is the one the client also receives. Place
it inside an error wrapper so 500s are still logged.

```erlang
Stack = [
    {livery_request_id, undefined},
    livery_middleware:wrap(fun my_app:errors_to_resp/3),
    {livery_access_log, #{}},
    %% ... business middlewares and handler
].
```

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Recipe: [Propagate request IDs](propagate-request-ids.md)
