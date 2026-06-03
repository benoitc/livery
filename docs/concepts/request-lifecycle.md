# Request lifecycle

This page follows one request from the moment it lands on a listener to
the moment its response is on the wire. Knowing this path explains the
two things that surprise people coming from other frameworks: why a
handler may block freely, and why a handler crash never takes the server
down.

The short version: **every request gets its own process.** The adapter
spawns a worker, the worker runs your middleware and handler, and it
writes the response back through the adapter. The listener process is
never the one running your code, so a slow or crashing handler cannot
stall or sink it.

## Sequence

```
client                  adapter                 worker              handler
  │                        │                       │                  │
  │── headers + body ───→ │                       │                  │
  │                        │── start_request ─────→│  (proc_lib:spawn)│
  │                        │   (adapter, stream,   │                  │
  │                        │    req, stack, fun)   │                  │
  │── body chunk ───────→ │                       │                  │
  │                        │── {livery_body, ...} →│                  │
  │                        │                       │── dispatch ─────→│
  │                        │                       │   middleware →   │
  │                        │                       │   handler        │
  │                        │                       │←── #livery_resp{}│
  │                        │←── send_headers ──────│ via livery:emit  │
  │                        │←── send_data ─────────│                  │
  │                        │←── send_trailers ─────│                  │
  │←── response ──────────│                       │                  │
  │                        │                       │── exit normal ───│
```

## Steps in detail

1. The wire library decodes a request and calls the adapter's inbound
   callback with the method, path, headers, and a stream handle.
2. The adapter builds an initial request value and calls
   `livery_req_sup:start_request/1` with the adapter, stream, request,
   middleware stack, and handler.
3. `start_request/1` admits the request against the concurrency cap and,
   if there is room, spawns a `livery_req_proc` worker directly with
   `proc_lib:spawn` (not a supervised child; see the note below). The
   worker receives the body, chunk by chunk, as `{livery_body, Ref, _}`
   messages.
4. The worker runs `livery:dispatch/3`: the middleware stack, then the
   handler.
5. The handler returns a `#livery_resp{}` value.
6. The worker walks that response with `livery:emit/3`, which calls the
   adapter's `send_headers`, `send_data`, and `send_trailers` in turn.
7. The worker exits normally. If anything in step 4 to 6 crashed, the
   worker maps it to a `500` (when nothing was sent yet) and still exits
   normally, so the failure stays contained.

The worker doing the dispatch is `livery_req_proc`; the entry point is
`run/1`. The whole of it:

```erlang
dispatch(Adapter, Stream, Stack, Handler, Req) ->
    Resp = livery:dispatch(Stack, Handler, Req),
    livery:emit(Adapter, Stream, Resp).
```

## Body messages

The body protocol on the worker's mailbox:

```text
{livery_body, Ref, {data, IoData}}
{livery_body, Ref, {trailers, [{Name, Value}]}}
{livery_body, Ref, eof}
{livery_body, Ref, {reset, Reason}}
```

You do not match these by hand. The request carries a reader, and
`livery_body:read/2` (one chunk) or `livery_body:read_all/1` (the whole
body) drains them for you. Messages with other tags are left untouched,
which is exactly why a streaming handler can `receive` its own
application messages in the same loop. See
[Streaming and backpressure](streaming-and-backpressure.md).

## Why you can block in a handler

Because the handler owns its process, you may call `receive`, sleep, wait
on a `gen_server`, or loop for as long as the request lives, without a
yield or a callback in sight. This is what makes the streaming producer
in the previous page a plain recursive function. The listener keeps
accepting new connections the whole time; it handed your request to its
own worker and moved on.

## Cancellation

When the client resets the stream or drops the connection, the wire
library tells the adapter, and the adapter's per-stream translator
notifies the worker. Two things happen: the worker is sent a
`{livery_disconnect, Ref, Reason}` message (match it with
`livery_req:disconnect_tag/0`) so a handler parked in a `receive` wakes
up, and any callbacks registered with `livery_req:on_disconnect/2` run. A
handler that is mid-`send_data` instead sees `{error, closed}` from the
next write. Either signal is your cue to stop and clean up.

## Graceful shutdown

`livery_req_sup` keeps a lock-free count of in-flight requests in a
`counters` array: it bumps the count when a worker is admitted and drops
it when the worker exits (it monitors each one, so even a killed worker
is accounted for). `livery_drain:in_flight/0` reads that count.

Draining uses it: stop the listeners from accepting new connections, wait
for the in-flight count to reach zero within a window, then stop the
service. See [Shut down gracefully](../guides/graceful-shutdown.md).

> **Note:** earlier versions ran each worker as a supervised child and
> counted in-flight requests as the supervisor's active children. That
> single supervisor became a serialization point on the hot path, so the
> worker is now spawned directly and the count lives in a `counters` ref.
> The externally visible behaviour (drain, the `500`-on-crash mapping) is
> unchanged.

## See also

- Concept: [Architecture](architecture.md)
- Concept: [Streaming and backpressure](streaming-and-backpressure.md)
- Guide: [Shut down gracefully](../guides/graceful-shutdown.md)
- Tutorial: [Build a complete service](../tutorials/build-a-complete-service.md)
- Reference: `livery_req_proc`, `livery_drain`
