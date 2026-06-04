# How to read a streaming request body

## Problem

Someone is uploading a file that would never fit comfortably in
memory, or you simply want to start working on the bytes the moment
they arrive instead of waiting for the whole thing. For that, you read
the body as a stream rather than buffering it.

## Solution

When `livery_req:body/1` hands you `{stream, Reader}`, drain it with
`livery_body:read/2` chunk by chunk, or `livery_body:read_all/2` in one
go:

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

If your handler bails out early, say auth failed or validation
tripped, throw away the rest of the body so the adapter does not sit
there waiting:

```erlang
{ok, _R1} = livery_body:discard(R0, 1_000),
livery_resp:text(401, <<"nope">>).
```

## Cap the size

You can pair this with `livery_body_limit` (buffered only for now), or
keep a running byte count of your own as you call `livery_body:read/2`
and stop once you have had enough.

## Backpressure

`livery_body:signal_demand(R, N)` tells the adapter you are ready for
`N` more bytes. The H1/H2/H3 adapters turn that into engine-level
window updates. It is a no-op for the test adapter, and on H1 it maps
to `h1`'s read size.

## See also

- Reference: `livery_body`
- Concepts: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
