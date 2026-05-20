# Request lifecycle

What happens between "a request hits the listener" and "the
response is on the wire".

## Sequence

```
client                  adapter                req_proc            handler
  │                        │                       │                  │
  │── headers + body ───→ │                       │                  │
  │                        │                       │                  │
  │                        │── start_link ────────→│                  │
  │                        │   (adapter, stream,   │                  │
  │                        │    req, stack, fun)   │                  │
  │                        │                       │                  │
  │── body chunk ───────→ │                       │                  │
  │                        │── {livery_body, ...} →│                  │
  │                        │                       │── dispatch ─────→│
  │                        │                       │   middleware →   │
  │                        │                       │   handler        │
  │                        │                       │←── #livery_resp{}│
  │                        │                       │                  │
  │                        │←── send_headers ──────│ via livery:emit  │
  │                        │←── send_data ─────────│                  │
  │                        │←── send_trailers ─────│                  │
  │←── response ──────────│                       │                  │
  │                        │                       │                  │
  │                        │                       │── exit normal ───│
```

## Steps in detail

1. The wire library decodes a request and invokes the adapter's
   inbound callback with method, path, headers, and a stream
   handle.
2. The adapter constructs an initial `#livery_req{}` and calls
   `livery_req_sup:start_request/1` with the stream, request, stack,
   and handler.
3. The supervisor starts a `livery_req_proc` worker. The worker
   receives subsequent body chunks as `{livery_body, Ref, _}`
   messages.
4. The worker runs `livery:dispatch/3`: middleware stack first,
   then handler.
5. The handler returns a `#livery_resp{}`.
6. The worker walks the body variant via `livery:emit/3` into the
   adapter callbacks. Headers, body bytes, trailers.
7. The worker exits normally. A crash inside dispatch is mapped to
   `500` and the worker still exits normally.

## Body messages

The body protocol on the worker's mailbox:

```
{livery_body, Ref, {data, IoData}}
{livery_body, Ref, {trailers, [{Name, Value}]}}
{livery_body, Ref, eof}
{livery_body, Ref, {reset, Reason}}
```

`livery_body:read/2` drains them. Other messages in the mailbox
are left alone, so the worker can also receive its own
application messages (for streaming responses driven by external
publishers).

## Streaming response

When the body variant is `{chunked, Producer}` or `{sse, Producer}`,
the producer fun runs inside the worker. It is free to `receive`
and may hibernate during idle stretches.

## Cancellation

A client disconnect is signaled by the wire library to the adapter
as a stream reset. The adapter calls `livery_req_proc` (a future
hook in Phase 2+) to cancel; alternatively the worker observes
`{error, closed}` from the next `send_data` and breaks out of its
producer loop.

## See also

- Concept: [Architecture](architecture.md)
- Concept: [Streaming and backpressure](streaming-and-backpressure.md)
- Reference: `livery_req_proc`
