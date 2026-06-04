# How to return a streaming response

## Problem

The response is too big, or too slow to produce, to build up in
memory first - a large file, a report you generate as you go, a feed
of events. You want to send the bytes out in pieces, as they become
ready, and let the client start reading right away.

## Solution

`livery_resp:stream/3` takes a status, some headers, and a producer
fun. The fun gets an `Emit` and calls it once per chunk:

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

The producer runs in the per-request process, and you simply return
from it when there is nothing left to emit.

## Stream from a message source

Because the producer is an ordinary process, it is free to
`receive`. That makes it easy to subscribe to a publisher and
forward whatever comes in:

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

`Emit/1` hands back the adapter's send result. When the client hangs
up, the H1/H2/H3 adapters return `{error, closed}`, which is your cue
to stop and clean up:

```erlang
case Emit(Chunk) of
    ok           -> loop(...);
    {error, _R}  -> cleanup(), ok
end.
```

(The test adapter always returns `ok`, so it never trips this path.)

## NDJSON

Streaming a sequence of JSON objects? `livery_resp:ndjson/2` handles
both the encoding and the `\n` framing for you:

```erlang
livery_resp:ndjson(200, fun(Emit) ->
    [Emit(#{n => N}) || N <- lists:seq(1, 5)],
    ok
end).
```

Each `Emit(Term)` calls `json:encode(Term)` and tacks a literal `\n`
onto the chunk. Content-Type defaults to `application/x-ndjson`. If
your bytes are already encoded, just drop down to `stream/3`.

## See also

- Recipe: [Return Server-Sent Events](server-sent-events.md)
- Tutorial: [Stream a response](../tutorials/streaming-responses.md)
- Concepts: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
