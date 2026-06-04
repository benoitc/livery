# How to serve WebTransport

## Problem

You need bidirectional streams and datagrams between browser and
server, the kind of low-latency, multiplexed channel WebSockets
never quite gave you. That is WebTransport, and it runs over HTTP/3
(or HTTP/2). This guide shows how to accept those sessions straight
from a Livery handler.

## Solution

`livery_wt:upgrade/3` accepts a WebTransport session on an
extended-CONNECT request and hands the stream to the
`webtransport` library, driven by a handler you implement
(`webtransport_handler` behaviour).

First, the listener has to advertise the WebTransport settings, or
the client never gets the chance to upgrade. Merge in
`webtransport:h3_settings/0` (H3) or `webtransport:h2_settings/0`
(H2), and the adapter takes care of forwarding the SETTINGS, the
datagram support, and the stream routing to the wire library:

```erlang
Handler = fun(Req) -> livery_wt:upgrade(Req, my_wt_handler, #{}) end,
Opts = maps:merge(webtransport:h3_settings(), #{
    cert => Cert, key => Key, stack => [], handler => Handler
}),
{ok, _} = livery_h3:start(Opts).
```

WebTransport lives on H3 and H2 (RFC 9220 extended CONNECT). There
is no such thing over plain H1, so there `upgrade/3` simply returns
`501`.

## Implement the session handler

The actual session logic goes in `my_wt_handler`, which implements
the `webtransport_handler` behaviour (from `erlang-webtransport`).
Here is an echo handler to get you started:

```erlang
-module(my_wt_handler).
-behaviour(webtransport_handler).
-export([init/3, handle_stream_fin/4, handle_datagram/2]).

init(Session, _Req, _Opts) -> {ok, #{session => Session}}.

handle_stream_fin(StreamId, bidi, Data, State) ->
    {ok, State, [{send, StreamId, Data, fin}]};
handle_stream_fin(_StreamId, uni, _Data, State) ->
    {ok, State}.

handle_datagram(Data, State) ->
    {ok, State, [{send_datagram, Data}]}.
```

## Notes

- On success `upgrade/3` returns the `taken_over` sentinel. From
  that point the session belongs to the `webtransport` process, so
  do not stack response-mutating middleware after it.
- Requires `webtransport` >= 0.2.3 (so `accept/4` works from
  Livery's per-request worker process).
- See `livery_wt_SUITE` for an end-to-end bidi-stream and datagram
  echo over H3.

## See also

- Reference: `livery_wt`, and the `erlang-webtransport` docs for
  the session API and handler behaviour.
- Concept: [Adapters](../concepts/adapters.md)
