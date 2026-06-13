# How to read a streaming request body

`livery_body` lets a handler consume the request body chunk by chunk.
You need it when the body is too large to buffer, or when you want to
process bytes as they arrive.

## Drain the stream

When `livery_req:body/1` returns `{stream, Reader}`, drain it via
`livery_body:read/2` or `livery_body:read_all/2`:

```erlang
upload(Req) ->
    {stream, R0} = livery_req:body(Req),
    consume(R0).

consume(R) ->
    case livery_body:read(R, 5_000) of
        {ok, Chunk, R1} ->
            ok = store:append(Chunk),
            consume(R1);
        {done, _R1} ->
            livery_resp:empty(204);
        {error, timeout, _} ->
            livery_resp:text(408, <<"slow client">>);
        {error, {client_reset, _}, _} ->
            livery_resp:empty(499)
    end.
```

## Read everything at once

```erlang
case livery_body:read_all(R0, 30_000) of
    {ok, Bytes, _R1}    -> use(Bytes);
    {error, Reason, _R} -> livery_resp:text(400, atom_to_binary(Reason))
end.
```

## Discard the rest

If the handler decides to short-circuit (auth failure, validation),
drop the remaining body so the adapter does not stall:

```erlang
{ok, _R1} = livery_body:discard(R0, 1_000),
livery_resp:text(401, <<"nope">>).
```

## Cap the size

Combine with `livery_body_limit` (buffered only today) or call
`livery_body:read/2` with a maximum byte count tracked yourself.

## Signal backpressure

`livery_body:signal_demand(R, N)` hints the adapter that the handler
is ready for `N` more bytes. The H1/H2/H3 adapters translate this into
engine-level window updates. This is a no-op for the test adapter; the
H1 adapter wires it to `h1`'s read size.

## See also

- Reference: `livery_body`
- Concepts: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
