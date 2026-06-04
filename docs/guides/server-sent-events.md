# How to return Server-Sent Events

## Problem

You want to push a stream of updates to the browser - a live
counter, a progress feed, notifications - and the client is reading
them with the EventSource API (or any RFC 8895 consumer). That means
it expects `text/event-stream` framing, and you want Livery to do
the framing so you can just emit events.

## Solution

```erlang
events(_Req) ->
    livery_resp:sse(200, fun(Emit) ->
        Emit(#{event => <<"tick">>, data => <<"1">>}),
        Emit(#{event => <<"tick">>, data => <<"2">>}),
        ok
    end).
```

`livery_resp:sse/2` sets `content-type: text/event-stream` and
`cache-control: no-cache` for you. Your producer fun runs in the
per-request process and drives `Emit`, one event at a time.

## Event shape

`Emit` accepts:

- A map `#{event, id, retry, data}` where any field is optional
  except `data`. Livery formats it into the standard SSE frame.
- Plain `iodata()`, framed as a `data:` line only.

```erlang
Emit(#{event => <<"ping">>, data => <<"pong">>}).
%% event: ping
%% data: pong
%%
%% (blank line terminates the frame)

Emit(#{event => <<"update">>, id => <<"42">>,
       retry => 1500, data => <<"v">>}).
%% event: update
%% id: 42
%% retry: 1500
%% data: v
%%

Emit(<<"plain">>).
%% data: plain
%%
```

Multi-line data is fine. Pass an iolist whose bytes contain `\n` and
Livery gives each line its own `data:` prefix. Just hand it an
`iolist` of lines:

```erlang
Emit(#{data => [<<"line 1">>, <<"\nline 2">>]}).
```

## Heartbeats

Idle connections have a habit of being dropped by proxies. To keep
yours alive, emit a comment line every so often (a line that begins
with `:`):

```erlang
loop(Emit) ->
    receive
        {event, E} -> Emit(E), loop(Emit)
    after 15_000 ->
        Emit(<<":heartbeat">>),
        loop(Emit)
    end.
```

## Disconnect detection

When the client goes away, `Emit` tells you: it returns
`{error, closed}` once the connection is gone. The H1/H2/H3 adapters
surface this; the test adapter always returns `ok`. Watch for it so
you can stop producing and clean up.

```erlang
loop(Emit) ->
    receive {event, E} ->
        case Emit(E) of
            ok          -> loop(Emit);
            {error, _}  -> ok
        end
    end.
```

## See also

- Recipe: [Return a streaming response](stream-chunked.md)
- Tutorial: [Stream a response](../tutorials/streaming-responses.md)
