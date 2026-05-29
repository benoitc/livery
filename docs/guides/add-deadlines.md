# How to add per-request deadlines

## Problem

A handler should return within a bounded time; if it does not, the
client receives `504` instead of a hung response.

## Solution

```erlang
Stack = [
    {livery_timeout, #{after_ms => 30_000}}   %% 30 second deadline
    %% ... handler
].
```

`livery_timeout` runs the rest of the pipeline in a monitored
worker process. If the worker does not return within `after_ms`,
the process is killed and `504` is emitted. Handler crashes are
mapped to `500`.

## Caveat: streaming request bodies

The deadline runs in a spawned, monitored worker, but body messages
from the adapter target the original request process
(`livery_req_proc`). Handlers that read body chunks via
`livery_body:read/2` will not see them under this middleware.
Workarounds:

- Place a body-buffering middleware in front of `livery_timeout`.
- Apply the middleware only to routes whose handlers do not stream
  input.

## Per-route deadlines

Stack the middleware multiple times with different keys, or mount
separate stacks per route group:

```erlang
FastApi    = [{livery_timeout, #{after_ms => 1_000}} | Common],
LongPolls  = [{livery_timeout, #{after_ms => 60_000}} | Common].
```

## Skipping for long-lived streams

SSE and chunked streaming handlers are open-ended by design. Do
not place `livery_timeout` in front of them. If you need an idle
timer for streams, implement it inside the producer with `receive
... after Ms`.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Reference: `livery_resp`
