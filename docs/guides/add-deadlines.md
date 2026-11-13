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

`livery_timeout` runs the rest of the pipeline in a monitored process.
If it does not return within `after_ms`, the process is killed and
`504` is emitted. Handler crashes are mapped to `500`.

Your handler does not notice the extra process. It reads a streamed
request body as usual, receives `{livery_disconnect, _, _}` if the
client goes away, and keeps the logger metadata and trace context set
before it. A `livery_concurrency` slot taken behind the timeout is
given back after the response is sent, or when the deadline cuts the
request off.

## Set per-route deadlines

Stack the middleware multiple times with different keys, or mount
separate stacks per route group:

```erlang
FastApi    = [{livery_timeout, #{after_ms => 1_000}} | Common],
LongPolls  = [{livery_timeout, #{after_ms => 60_000}} | Common].
```

## Notes

- The deadline covers the time until your handler returns its
  response. A streamed response (SSE, chunked) is produced after that,
  so it is not bounded by `after_ms`. If a stream needs an idle limit,
  put it in the producer with `receive ... after Ms`.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Reference: `livery_resp`
