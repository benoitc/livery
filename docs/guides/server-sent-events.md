# How to return Server-Sent Events

`livery_resp:sse/2` sends events to the client in the
`text/event-stream` format of the HTML standard. You need it when your
client uses the EventSource API (or any client that reads that format)
and expects events sent one way, from server to client, over a response
that stays open.

## Stream events

```erlang
events(_Req) ->
    livery_resp:sse(200, fun(Emit) ->
        Emit(#{event => <<"tick">>, data => <<"1">>}),
        Emit(#{event => <<"tick">>, data => <<"2">>}),
        ok
    end).
```

`livery_resp:sse/2` sets `content-type: text/event-stream` and
`cache-control: no-cache`. The producer fun runs in the request's
process and calls `Emit` once for each event.

## Shape an event

`Emit` accepts:

- A map `#{event, id, retry, data}` where only `data` is required.
  Livery writes it out as a standard SSE event.
- Plain `iodata()`, sent as a `data:` line and nothing else.

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

Multi-line data is fine: Livery gives each line its own `data:`
prefix, whether the lines end in `\n`, `\r\n` or `\r`, and the
browser joins them back:

```erlang
Emit(#{data => <<"line 1\nline 2">>}).
%% data: line 1
%% data: line 2
```

Line breaks are removed from `event` and `id` (and NUL from `id`), so a
value can never start another field. `retry` is sent only as a number
of milliseconds, an integer or a string of digits; anything else is
left out.

## Keep idle connections alive

Proxies may close a connection that stays quiet. To keep it open, send
a comment every so often with `Emit({comment, Text})`. It goes out as a
line that starts with `:`, which the client ignores:

```erlang
loop(Emit) ->
    receive
        {event, E} -> Emit(E), loop(Emit)
    after 15_000 ->
        Emit({comment, <<"heartbeat">>}),
        loop(Emit)
    end.
```

## Detect a disconnect

`Emit` returns `{error, closed}` once the client disconnects (the
H1/H2/H3 adapters report it; the test adapter always returns `ok`):

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

- Guide: [Return a streaming response](stream-chunked.md)
- Tutorial: [Stream a response](../tutorials/streaming-responses.md)
