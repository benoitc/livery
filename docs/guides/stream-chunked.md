# How to return a streaming response

## Problem

You need to emit response body bytes incrementally rather than
buffering the whole payload in memory.

## Solution

`livery_resp:stream/3` takes a status, headers, and a producer fun
that drives chunk emission:

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

The producer runs in the per-request process. It returns when there
is nothing more to emit.

## Stream from a message source

The producer is free to `receive`. Subscribe to a publisher and
forward events:

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

`Emit/1` returns the adapter's send result. On client disconnect
the H1/H2/H3 adapters return `{error, closed}`. Break out:

```erlang
case Emit(Chunk) of
    ok           -> loop(...);
    {error, _R}  -> cleanup(), ok
end.
```

The test adapter always returns `ok`.

## NDJSON

`livery_resp:ndjson/2` does the JSON encoding and the `\n` framing
for you:

```erlang
livery_resp:ndjson(200, fun(Emit) ->
    [Emit(#{n => N}) || N <- lists:seq(1, 5)],
    ok
end).
```

Each `Emit(Term)` calls `json:encode(Term)` and appends a literal
`\n` to one chunk. Content-Type defaults to
`application/x-ndjson`. For pre-encoded bytes, drop down to
`stream/3`.

## See also

- Recipe: [Return Server-Sent Events](server-sent-events.md)
- Tutorial: [Stream a response](../tutorials/streaming-responses.md)
- Concepts: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
