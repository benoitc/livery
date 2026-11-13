# How to read a streaming request body

`livery_body` lets a handler read the request body one chunk at a
time. You need it when the body is too large to keep in memory, or when
you want to work on the bytes as they arrive.

## Drain the stream

When `livery_req:body/1` returns `{stream, Reader}`, read it with
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

If the handler answers early (a failed auth check, invalid input),
throw away the rest of the body so the adapter does not get stuck:

```erlang
{ok, _R1} = livery_body:discard(R0, 1_000),
livery_resp:text(401, <<"nope">>).
```

## Cap the size

Put `livery_body_limit` in the stack: once the handler has read more
than its `max`, `livery_body:read/2` returns
`{error, body_too_large, _}`. You can also count the bytes yourself as
you call `livery_body:read/2`.

## Backpressure

Nothing to do: each chunk `livery_body:read/2` returns gives its flow
control credit back, so a client sends only one flow window ahead of
what you have read, on every protocol. Read at the pace you can
process.
`livery_body:signal_demand/2` is deprecated: `read/2` already does its
job.

## See also

- Reference: `livery_body`
- Concepts: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
