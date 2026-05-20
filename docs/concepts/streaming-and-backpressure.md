# Streaming and backpressure

Livery streams bytes both ways and applies backpressure rather than
unbounded buffering when either side stalls.

## Inbound streaming

Inbound body arrives at the per-request process as messages:

```
{livery_body, Ref, {data, IoData}}
{livery_body, Ref, {trailers, [...]}}
{livery_body, Ref, eof}
{livery_body, Ref, {reset, Reason}}
```

`livery_body:read/2` drains one message per call. `read_all/2`
loops until `eof` or `reset`.

Backpressure on the inbound side is per-protocol:

- **H1**: limit the wire library's read size; the kernel TCP window
  closes naturally when the application stops reading.
- **H2**: WINDOW_UPDATE frames. The wire library issues them in
  response to `livery_body:signal_demand/2`.
- **H3**: QUIC flow control credits. Same demand hook.

`livery_body:signal_demand(R, N)` is a no-op for adapters without a
demand mechanism, and a window update for the others.

## Outbound streaming

The producer fun inside `livery_resp:stream/3` (or `:sse/2`) runs
in the per-request process. It drives `Emit(IoData)` one chunk at
a time. Each `Emit` returns the adapter's `send_data` result:

- `ok` — proceed.
- `{error, closed}` — peer disconnected. Stop and clean up.
- `{error, flow}` — temporary backpressure; retry after a wait.
- `{error, _Other}` — adapter-specific error.

The producer can `receive` between emits, sleep, or block on a
mailbox message. Nothing else in the process competes for control.

## Backpressure on the outbound side

The wire library cooperates with the adapter to apply
backpressure when the client cannot keep up:

- **H1**: `gen_tcp` `{active, false}` plus `send/2` blocks on a
  full kernel buffer.
- **H2**: stream-level WINDOW_UPDATE; `send_data` returns
  `{error, flow}` when there is no credit.
- **H3**: same, on QUIC stream credits.

The recommended pattern is to drive `Emit` to completion and react
on error returns:

```erlang
fun(Emit) -> stream_loop(Source, Emit) end.

stream_loop(Source, Emit) ->
    case next(Source) of
        {ok, Chunk, Source1} ->
            case Emit(Chunk) of
                ok          -> stream_loop(Source1, Emit);
                {error, _}  -> cleanup(Source1)
            end;
        done -> ok
    end.
```

## Disconnect detection

A client disconnect surfaces as:

- An error return from `Emit` (above), or
- A `{livery_body, Ref, {reset, _}}` message in the worker mailbox.

Either way, the producer is the one responsible for stopping. The
worker process terminates when the producer returns, regardless of
whether the disconnect was clean.

## Hibernation

Long-lived idle streams (slow LLM tokens, infrequent updates)
should hibernate to reduce memory footprint:

```erlang
stream_loop(Source, Emit) ->
    receive
        {Source, Event} ->
            Emit(format(Event)),
            stream_loop(Source, Emit)
    after 30_000 ->
        erlang:hibernate(?MODULE, stream_loop, [Source, Emit])
    end.
```

The per-request process is a regular BEAM process, so
`erlang:hibernate/3` works as usual.

## See also

- Reference: `livery_body`
- Reference: `livery_resp`
- Tutorial: [Stream a response](../tutorials/streaming-responses.md)
