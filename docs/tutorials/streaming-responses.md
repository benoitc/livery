# Tutorial: Stream a response

In this tutorial you build three streaming endpoints: chunked
bytes, Server-Sent Events, and a long-running progress feed driven
by a separate process. It is for you once you can write a plain
handler and want to send a body in pieces rather than all at once.
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

The fun that produces the body runs in the request's own process and
is called with an `Emit` callback. Each `Emit(IoData)` is sent as one
body chunk. The fun returns when there is nothing more to send.

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
the `cache-control: no-cache` header. The `Emit` callback turns
each map into an SSE event, with its `event:`, `id:`, `retry:` and
`data:` lines.

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

The request's process is an ordinary Erlang process. On OTP 28 and
later it can call `erlang:hibernate/0` while it waits for the next
event; avoid `erlang:hibernate/3`, which never returns to the loop.

This is how Livery replaces Cowboy's `cowboy_loop` handlers. There are
no `init/2`, `info/3` and `terminate/3` callbacks: the streaming handler
is a fun that calls `Emit` until it has nothing more to send.

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
adapters tell you the client went away through this return value.

## Next steps

- Guide: [Return Server-Sent Events](../guides/server-sent-events.md)
- Guide: [Return a streaming response](../guides/stream-chunked.md)
- Concepts: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
