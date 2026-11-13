# How to return a streaming response

`livery_resp:stream/3` takes a status, headers, and a producer fun
that sends the body in chunks. You need it when you want to send the
response body piece by piece instead of holding all of it in memory.

## Stream from a file

```erlang
download(_Req) ->
    livery_resp:stream(200,
        [{<<"content-type">>, <<"application/octet-stream">>}],
        fun(Emit) ->
            stream_file("/var/data/big.bin", Emit)
        end).

stream_file(Path, Emit) ->
    {ok, F} = file:open(Path, [read, binary]),
    try
        emit_chunks(F, Emit)
    after
        file:close(F)
    end.

emit_chunks(F, Emit) ->
    case file:read(F, 65_536) of
        {ok, Chunk} -> Emit(Chunk), emit_chunks(F, Emit);
        eof         -> ok
    end.
```

The producer runs in the request's process, and returns when it has
nothing more to send.

## Stream from a message source

The producer can `receive` messages. Here it subscribes to a
publisher and forwards its events:

```erlang
follow(_Req) ->
    livery_resp:stream(200,
        [{<<"content-type">>, <<"text/plain">>}],
        fun(Emit) ->
            Ref = log_pubsub:subscribe(self()),
            loop(Ref, Emit)
        end).

loop(Ref, Emit) ->
    receive
        {Ref, {line, L}} -> Emit([L, <<"\n">>]), loop(Ref, Emit);
        {Ref, eof}        -> ok
    end.
```

## Detect disconnect

`Emit/1` returns what the adapter's send returned. When the client
disconnects, the H1/H2/H3 adapters return `{error, closed}`. Stop
there:

```erlang
case Emit(Chunk) of
    ok           -> loop(...);
    {error, _R}  -> cleanup(), ok
end.
```

The test adapter always returns `ok`.

## Stream NDJSON

NDJSON (newline-delimited JSON) puts one JSON value per line.
`livery_resp:ndjson/2` encodes each value and adds the `\n` for you:

```erlang
livery_resp:ndjson(200, fun(Emit) ->
    [Emit(#{n => N}) || N <- lists:seq(1, 5)],
    ok
end).
```

Each `Emit(Term)` calls `json:encode(Term)` and sends the result with
a `\n` after it, as one chunk. Content-Type defaults to
`application/x-ndjson`. If your bytes are already encoded, use
`stream/3` instead.

## See also

- Guide: [Return Server-Sent Events](server-sent-events.md)
- Tutorial: [Stream a response](../tutorials/streaming-responses.md)
- Concepts: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
