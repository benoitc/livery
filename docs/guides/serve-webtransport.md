# How to serve WebTransport

`livery_wt:upgrade/3` accepts a WebTransport session (bidirectional
and unidirectional streams, and datagrams) on an extended CONNECT
request and hands the stream to the `webtransport` library. You need
it when a client wants a low-latency channel in both directions over
HTTP/3 (or HTTP/2), run by a handler you write (`webtransport_handler`
behaviour).

## Advertise the settings and upgrade

The listener must announce the WebTransport settings to clients.
Merge `webtransport:h3_settings/0` (H3) or `webtransport:h2_settings/0`
(H2) into the listener options; the adapter passes the SETTINGS,
datagram support and stream routing on to the wire library:

```erlang
Handler = fun(Req) -> livery_wt:upgrade(Req, my_wt_handler, #{}) end,
Opts = maps:merge(webtransport:h3_settings(), #{
    cert => Cert, key => Key, stack => [], handler => Handler
}),
{ok, _} = livery_h3:start(Opts).
```

WebTransport runs over H3 and H2 (extended CONNECT: RFC 9220 on H3,
RFC 8441 on H2). On
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
  not stack middleware that changes the response after it.
- Livery uses `webtransport` 0.5, which speaks draft-17 over H3
  and draft-16 over H2. Chrome and Firefox (draft-02) and Safari 26
  (draft-07) still connect over H3.
- Over H2, a session needs TLS 1.3. A client that negotiated TLS 1.2
  has its request reset, so keep TLS 1.3 enabled on the `https`
  listener (it is, unless you narrow `versions` in `ssl_opts`).
- If opening a stream fails because the peer allows no more, your
  handler's `handle_stream_credit/2` is called once it can try again.
- See `livery_wt_SUITE` for a full echo example over H3, with a
  bidirectional stream and datagrams.

## See also

- Reference: `livery_wt`, and the `erlang-webtransport` docs for
  the session API and handler behaviour.
- Concept: [Adapters](../concepts/adapters.md)
