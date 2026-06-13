# How to add per-request deadlines

`livery_timeout` is a middleware that bounds how long a handler may
run. You need it when a slow handler would otherwise hang the client:
instead of waiting forever, the client gets a `504`.

## Add it to the stack

```erlang
Stack = [
    {livery_timeout, #{after_ms => 30_000}}   %% 30 second deadline
    %% ... handler
].
```

`livery_timeout` runs the rest of the pipeline in a monitored worker
process. If the worker does not return within `after_ms`, the process
is killed and `504` is emitted. Handler crashes are mapped to `500`.

## Set per-route deadlines

Stack the middleware multiple times with different keys, or mount
separate stacks per route group:

```erlang
FastApi    = [{livery_timeout, #{after_ms => 1_000}} | Common],
LongPolls  = [{livery_timeout, #{after_ms => 60_000}} | Common].
```

## Notes

- Streaming request bodies: the deadline runs in a spawned, monitored
  worker, but body messages from the adapter target the original
  request process (`livery_req_proc`). Handlers that read body chunks
  via `livery_body:read/2` will not see them under this middleware.
  Either place a body-buffering middleware in front of
  `livery_timeout`, or apply the middleware only to routes whose
  handlers do not stream input.
- Long-lived streams: SSE and chunked streaming handlers are
  open-ended by design. Do not place `livery_timeout` in front of
  them. If you need an idle timer for streams, implement it inside the
  producer with `receive ... after Ms`.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Reference: `livery_resp`
