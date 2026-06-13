# How to serve WebTransport

`livery_wt:upgrade/3` accepts a WebTransport session (bidi/uni
streams and datagrams) on an extended-CONNECT request and hands the
stream to the `webtransport` library. You need it when a client
wants a low-latency bidirectional channel over HTTP/3 (or HTTP/2),
driven by a handler you implement (`webtransport_handler`
behaviour).

## Advertise the settings and upgrade

The listener must advertise the WebTransport settings. Merge
`webtransport:h3_settings/0` (H3) or `webtransport:h2_settings/0`
(H2) into the listener options; the adapter forwards the SETTINGS,
datagram support, and stream routing to the wire library:

```erlang
Handler = fun(Req) -> livery_wt:upgrade(Req, my_wt_handler, #{}) end,
Opts = maps:merge(webtransport:h3_settings(), #{
    cert => Cert, key => Key, stack => [], handler => Handler
}),
{ok, _} = livery_h3:start(Opts).
```

WebTransport runs over H3 and H2 (RFC 9220 extended CONNECT). On
H1, `upgrade/3` returns `501`.

## Implement the session handler

`my_wt_handler` implements the `webtransport_handler` behaviour
(from `erlang-webtransport`). An echo handler:

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

- On success `upgrade/3` returns the `taken_over` sentinel; the
  session belongs to the `webtransport` process after that, so do
  not stack response-mutating middleware after it.
- Requires `webtransport` >= 0.2.3 (so `accept/4` works from
  Livery's per-request worker process).
- See `livery_wt_SUITE` for an end-to-end bidi-stream and datagram
  echo over H3.

## See also

- Reference: `livery_wt`, and the `erlang-webtransport` docs for
  the session API and handler behaviour.
- Concept: [Adapters](../concepts/adapters.md)
