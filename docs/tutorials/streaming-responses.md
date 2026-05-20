# Tutorial: Stream a response

Build three streaming endpoints: chunked bytes, Server-Sent Events,
and a long-running progress feed driven by a separate process.
About 10 minutes.

## 1. Chunked bytes

```erlang
download(_Req) ->
    livery_resp:stream(200,
        [{<<"content-type">>, <<"application/octet-stream">>}],
        fun(Emit) ->
            [Emit(integer_to_binary(N)) || N <- lists:seq(1, 10)],
            ok
        end).
```

The producer fun runs in the per-request process and is called with
an `Emit` callback. Each `Emit(IoData)` becomes one body chunk on
the wire. The fun returns when there is nothing more to send.

```erlang
Cap = livery_test_adapter:run([], fun download/1, #{}),
?assertEqual(<<"12345678910">>, livery_test_adapter:body(Cap)).
```

## 2. Server-Sent Events

```erlang
events(_Req) ->
    livery_resp:sse(200, fun(Emit) ->
        Emit(#{event => <<"tick">>, data => <<"1">>}),
        Emit(#{event => <<"tick">>, data => <<"2">>}),
        ok
    end).
```

`livery_resp:sse/2` sets the `text/event-stream` content type and
the `cache-control: no-cache` header. The `Emit` callback formats
each map into a proper SSE frame (`event:`, `id:`, `retry:`, `data:`).

Plain bytes are accepted too:

```erlang
Emit(<<"plain text">>)   %% emits "data: plain text\n\n"
```

## 3. Receive-driven streams (the cowboy_loop replacement)

The producer fun is allowed to `receive` between emits. Subscribe
to an external source and forward events as they arrive:

```erlang
pull(_Req) ->
    livery_resp:stream(200,
        [{<<"content-type">>, <<"application/x-ndjson">>}],
        fun(Emit) ->
            Ref = pipeline:subscribe(self()),
            loop(Ref, Emit)
        end).

loop(Ref, Emit) ->
    receive
        {Ref, {progress, Pct}} ->
            Emit([json:encode(#{status => downloading, pct => Pct}), <<"\n">>]),
            loop(Ref, Emit);
        {Ref, done} ->
            Emit([json:encode(#{status => done}), <<"\n">>])
    end.
```

Hibernating between idle stretches is fine; the per-request process
is exactly that, a process.

This is the Livery replacement for Cowboy's `cowboy_loop` callback
shape. There is no `init/2`/`info/3`/`terminate/3` triad: the
streaming handler is just a fun that drives `Emit` until it has
nothing more to say.

## 4. Detecting client disconnect

The `Emit` callback returns the adapter's send result. When the
client is gone, it returns `{error, closed}` (or `{error, flow}`
under backpressure). Use it to break out of long loops:

```erlang
loop(Ref, Emit) ->
    receive
        {Ref, {progress, Pct}} ->
            case Emit([json:encode(#{pct => Pct}), <<"\n">>]) of
                ok           -> loop(Ref, Emit);
                {error, _}   -> pipeline:unsubscribe(Ref), ok
            end
    end.
```

The test adapter always returns `ok` from `Emit`. The real H1/H2/H3
adapters surface peer disconnect through this return value.

## Next steps

- Recipe: [Return Server-Sent Events](../guides/server-sent-events.md)
- Recipe: [Return a streaming response](../guides/stream-chunked.md)
- Concepts: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
