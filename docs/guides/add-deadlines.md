# How to add per-request deadlines

## Problem

Some handler reaches out to a slow database, a flaky upstream, or a
queue that occasionally stalls. You do not want a single request to
hang forever and tie up a client. You want a clear rule: return in
time, or the caller gets a `504` and moves on.

## Solution

```erlang
Stack = [
    {livery_timeout, #{after_ms => 30_000}}   %% 30 second deadline
    %% ... handler
].
```

`livery_timeout` runs the rest of the pipeline in a monitored
worker process. If the worker does not answer within `after_ms`,
Livery kills it and emits a `504`. And if your handler crashes on
its own, that becomes a `500`.

## Caveat: streaming request bodies

There is a catch worth knowing. The deadline runs in a spawned,
monitored worker, but body messages from the adapter still target
the original request process (`livery_req_proc`). So a handler that
reads body chunks with `livery_body:read/2` will never see them
under this middleware. Two ways around it:

- Place a body-buffering middleware in front of `livery_timeout`.
- Apply the middleware only to routes whose handlers do not stream
  input.

## Per-route deadlines

Not every route deserves the same patience. Stack the middleware
several times with different keys, or mount a separate stack per
route group:

```erlang
FastApi    = [{livery_timeout, #{after_ms => 1_000}} | Common],
LongPolls  = [{livery_timeout, #{after_ms => 60_000}} | Common].
```

## Skipping for long-lived streams

SSE and chunked streaming handlers are open-ended on purpose, so
do not put `livery_timeout` in front of them. If you want an idle
timer for a stream, build it right into the producer with `receive
... after Ms`.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Reference: `livery_resp`
