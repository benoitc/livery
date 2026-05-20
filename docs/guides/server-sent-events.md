# How to return Server-Sent Events

## Problem

Your client uses the EventSource API (or any RFC 8895 compatible
consumer) and expects `text/event-stream` framing.

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
`cache-control: no-cache`. The producer fun runs in the per-request
process and drives `Emit` with one event at a time.

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

Multi-line data is fine: pass an iolist whose bytes contain `\n`
and Livery emits each line with its own `data:` prefix when you use
the helper. For multi-line, use `iolist` of lines:

```erlang
Emit(#{data => [<<"line 1">>, <<"\nline 2">>]}).
```

## Heartbeats

To keep idle connections alive through proxies, emit a comment line
periodically (a line beginning with `:`):

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

`Emit` returns `{error, closed}` once the client disconnects (the
H1/H2/H3 adapters surface this; the test adapter always returns
`ok`).

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
