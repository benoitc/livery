# Streaming and backpressure

This page explains how you stream a body in either direction, where the
producing function lives, and what happens when one side cannot keep up.
Read it when a body is too large to hold in memory, or when you want
bytes to reach the client as they are produced. Most responses are one
short burst: a handler builds a value and Livery writes it. Streaming is
for the other kind, where the body arrives, or leaves, in pieces over
time.

The thing to remember: **a request runs in its own process** (the
per-request worker). So the function that produces a stream is free to
block, to `receive`, to wait on a database or another process. Nothing
else shares that process, so there is no callback to register and no
event loop to yield to. You write a normal Erlang loop.

## When to stream, and which one

Reach for streaming when the whole body should not, or cannot, sit in
memory at once, or when you want bytes to reach the client as they are
produced rather than at the end.

| You want to ... | Use | Content type |
|---|---|---|
| send a normal, complete body | `livery_resp:json/2`, `text/2`, `html/2` | as set |
| push live updates to a browser | `livery_resp:sse/2` | `text/event-stream` |
| stream records to a tool or service | `livery_resp:ndjson/2` | `application/x-ndjson` |
| stream arbitrary bytes (a big export) | `livery_resp:stream/3` | as set |
| send a file from disk | `livery_resp:file/2` | as set |

**Use `sse/2` when** the client is a browser `EventSource` or you want
named events that the browser reconnects to on its own: dashboards,
progress bars, notifications, LLM tokens. **Use `ndjson/2` when** the
reader is a CLI or another service reading one JSON object per line.
**Use `stream/3` when** you only need to send plain chunks of bytes (a
CSV report generated row by row, a proxied payload). **Prefer `file/2`** over
reading a file yourself; adapters that can will use `sendfile`.

## Outbound: where the producer lives

`livery_resp:stream/3`, `sse/2`, and `ndjson/2` all take a *producer*: a
function Livery hands an `Emit` callback to. You call `Emit` once per
chunk; Livery frames it and writes it. The producer runs inside the
per-request worker, so you can write it as a plain recursive function.

The following is an excerpt from `examples/livery_example_stream.erl`. The
handler is a one-liner; the real work is `tick/3`, a named top-level
function, so it is easy to read and to test:

```erlang
clock(_Req) ->
    livery_resp:sse(200, fun(Emit) -> tick(Emit, 10, 1000) end).

tick(_Emit, 0, _Interval) ->
    ok;
tick(Emit, Remaining, Interval) ->
    receive
        {livery_disconnect, _Ref, _Reason} ->
            ok
    after Interval ->
        Now = integer_to_binary(erlang:system_time(second)),
        case Emit(#{event => <<"tick">>, data => Now}) of
            ok         -> tick(Emit, Remaining - 1, Interval);
            {error, _} -> ok
        end
    end.
```

`Emit` returns the adapter's send result, and you act on it:

- `ok` - the chunk went out; keep going.
- `{error, closed}` - the peer is gone. Stop and clean up.
- `{error, send_buffer_full}` - temporary backpressure on HTTP/2 (see
  below); back off and retry.
- `{error, _Other}` - an adapter-specific failure; stop.

For `sse/2` you emit a map (`#{event => _, id => _, data => _}` or only
`data`); for `stream/3` and `ndjson/2` you emit `iodata` (ndjson encodes
and newline-frames each term for you).

## Outbound, receive-driven: the long-lived stream

The clock above paces itself with `after`. The more common shape is a
stream fed by *another* process: an LLM emitting tokens, a pub/sub topic,
a job reporting progress. The producer `receive`s those messages and
forwards them, and it also matches the disconnect message so it can stop
the upstream work when the client leaves. It does the job of Cowboy's
`cowboy_loop`.

```erlang
chat(Req) ->
    {ok, InferRef} = my_llm:start(prompt(Req)),   %% streams {token, InferRef, T}
    livery_resp:sse(200, fun(Emit) -> relay(Emit, InferRef) end).

relay(Emit, InferRef) ->
    receive
        {token, InferRef, T} ->
            case Emit(#{data => T}) of
                ok         -> relay(Emit, InferRef);
                {error, _} -> my_llm:cancel(InferRef)   %% client gone: stop work
            end;
        {done, InferRef} ->
            ok;
        {livery_disconnect, _Ref, _Reason} ->
            my_llm:cancel(InferRef)
    end.
```

The disconnect message tag is `livery_req:disconnect_tag/0`
(`livery_disconnect`). You do not register anything to get it; the worker
is sent `{livery_disconnect, Ref, Reason}` when the client resets the
stream. If your handler is not sitting in a `receive`, register a
callback instead with `livery_req:on_disconnect/2`. See
[Cancel on client disconnect](../guides/cancel-on-disconnect.md).

## Inbound: reading a streamed request body

A large upload arrives the same way, as messages on the worker's mailbox:

```text
{livery_body, Ref, {data, IoData}}
{livery_body, Ref, {trailers, [{Name, Value}]}}
{livery_body, Ref, eof}
{livery_body, Ref, {reset, Reason}}
```

You rarely match those yourself. The request carries a reader, and
`livery_body` reads them for you. To buffer the whole body (with a size
cap), use `read_all`:

```erlang
upload(Req) ->
    {stream, Reader} = livery_req:body(Req),
    {ok, Bin, _Reader1} = livery_body:read_all(Reader),
    livery_resp:text(201, integer_to_binary(byte_size(Bin))).
```

To process the body without ever holding all of it, loop with
`livery_body:read/2` (it returns one chunk per call) until `eof`, folding
as you go, for example hashing or counting:

```erlang
count_bytes(Reader, Acc) ->
    case livery_body:read(Reader, 5000) of
        {ok, Data, Reader1} -> count_bytes(Reader1, Acc + iolist_size(Data));
        {done, _Reader1}    -> Acc;
        {error, Reason, _}  -> {error, Reason}
    end.
```

See [Read a streaming request body](../guides/read-streaming-body.md).

## Backpressure

Backpressure means Livery stops buffering when one side falls behind,
so a slow client cannot make the server run out of memory. Each protocol
handles it its own way, and you mostly see it in return values.

**Outbound.** When the client's window is full, `send_data` does not
buffer forever:

- **H1**: the kernel socket buffer fills and the write blocks.
- **H2**: while the stream window is full, the data waits in the
  stream's send buffer. When that buffer would grow past 1 MiB, `Emit`
  returns `{error, send_buffer_full}` and the chunk is not queued.
- **H3**: `Emit` waits while the connection's send queue is full, the
  way an H1 write blocks. If the queue has not drained after 30 seconds
  the stream is reset and `Emit` returns `{error, send_timeout}`.

So for a producer the rule is: call `Emit` and act on its result. `ok`
means proceed, `{error, send_buffer_full}` means wait a moment and
retry the same chunk, `{error, closed}` or `{error, send_timeout}`
means give up.

**Inbound.** You do nothing: every chunk `livery_body:read/2` hands you
gives its flow-control credit back to the wire library, which lets the
client send that many more bytes. The client can send one
flow window ahead of what your handler has read (64 KiB on HTTP/1.1 and
per stream on HTTP/2 by default, 512 KiB on HTTP/3), then waits. A
handler that reads slowly holds the client back instead of letting the
body pile up in memory. If your handler answers without reading the
whole body, the client is told to stop sending the rest once the
response is out (on HTTP/1.1 the connection drains it, then closes).

## Failure modes

- **Client disconnects mid-stream.** You find out one of two ways: `Emit` returns
  `{error, closed}`, or a `{livery_disconnect, _, _}` message arrives.
  Stop and release upstream resources. The worker then exits.
- **The producer crashes.** Headers are usually already on the wire, so
  the crash cannot become a `500`; the stream resets instead. Do cleanup
  inside the loop (on the error and disconnect branches) rather than
  relying on a wrapper turning it into a response.
- **The body exceeds the limit.** With `livery_body_limit` in the stack,
  a body whose `Content-Length` is over the limit is answered `413`
  before your handler runs; any other body gets
  `{error, body_too_large, _}` from `livery_body:read/2` once the
  handler has read past the limit.

## Hibernation

A stream that is idle for long stretches (slow tokens, infrequent
updates) can hibernate so it costs almost no memory while it waits. On
OTP 28 and later, call `erlang:hibernate/0`: it returns when the next
message arrives, and the loop goes on where it was:

```erlang
relay(Emit, Source) ->
    receive
        {Source, Event} ->
            _ = Emit(#{data => format(Event)}),
            relay(Emit, Source)
    after 30_000 ->
        erlang:hibernate(),
        relay(Emit, Source)
    end.
```

Do not use `erlang:hibernate/3` here. It throws away the call stack, so
the producer never returns to Livery and the stream is never finished.

## See also

- Guide: [Return a streaming response](../guides/stream-chunked.md)
- Guide: [Return Server-Sent Events](../guides/server-sent-events.md)
- Guide: [Read a streaming request body](../guides/read-streaming-body.md)
- Guide: [Cancel on client disconnect](../guides/cancel-on-disconnect.md)
- Example: `examples/livery_example_stream.erl`
- Tutorial: [Build a complete service](../tutorials/build-a-complete-service.md)
- Reference: `livery_resp`, `livery_body`
