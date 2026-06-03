# Adapters

An adapter glues a wire library to Livery's request/response model.
Each adapter implements the `livery_adapter` behaviour.

## Behaviour

```erlang
-callback start(Name, ListenSpec, Opts) -> {ok, Listener}.
-callback stop(Listener) -> ok.
-callback send_headers(Stream, Status, Headers, SendOpts) -> SendResult.
-callback send_data(Stream, IoData, SendOpts) -> SendResult.
-callback send_trailers(Stream, Trailers) -> SendResult.
-callback reset(Stream, Reason) -> ok.
-callback peer_info(Stream) -> #{peer, tls, alpn}.
-callback capabilities(Listener) -> #{trailers, extended_connect, datagrams, capsules}.
```

`SendOpts` is `#{end_stream => boolean(), flush => boolean()}`.
`SendResult` is `ok | {error, closed | flow | term()}`.

## Adapters that ship

| Adapter | Serves | Backed by |
|---|---|---|
| `livery_test_adapter` | in-memory | ETS, no socket |
| `livery_h1` | HTTP/1.1 | `h1` |
| `livery_h2` | HTTP/2 | `h2` |
| `livery_h3` | HTTP/3 | `quic` (`quic_h3` subsystem) |

The test adapter exists so handlers can be exercised in EUnit and
the parity SUITE can run a single source of truth across every
adapter.

## What an adapter is not

- Not a state machine. Framing, header compression, flow control,
  and TLS belong to the wire library.
- Not a buffer. The body reader buffers, not the adapter.
- Not a router. Routing happens in middleware after the request
  reaches `livery_req_proc`.

If you find yourself writing complex logic inside an adapter, the
piece probably belongs in `h1`/`h2`/`quic` upstream or in a
middleware downstream.

## Adding a new adapter

1. Pick a wire library or implement one.
2. Implement the eight callbacks in a new `livery_xx` module with
   `-behaviour(livery_adapter).`.
3. Translate incoming engine events to `{livery_body, Ref, _}`
   messages addressed to the per-request process.
4. Add a group to `test/livery_parity_SUITE.erl` that drives the
   shared handler matrix through the new adapter.

## Capability gating

A handler can branch on adapter capabilities for optional features:

```erlang
Adapter = livery_req:adapter(Req),
case Adapter:capabilities(livery_req:stream(Req)) of
    #{trailers := true} ->
        livery_resp:with_trailers([{<<"x-fin">>, <<"1">>}], Resp);
    _ ->
        Resp
end.
```

`capabilities/1` is a `livery_adapter` callback; call it on the
concrete adapter module the request arrived on
(`livery_req:adapter/1`), not on `livery_adapter` itself.

`trailers` and `extended_connect` are protocol-specific. `datagrams`
and `capsules` apply to WebTransport on H3.

## Listen address

Every adapter takes the same `ip => inet:ip_address()` and
`inet6 => boolean()` listen options, translated to the underlying wire
library by `livery_inet:socket_addr_opts/1`. See
[Bind to an address or IPv6](../guides/bind-listen-address.md).

## See also

- Guide: [Bind to an address or IPv6](../guides/bind-listen-address.md)
- Reference: `livery_adapter`
- Reference: `livery_test_adapter`
- Concept: [Architecture](architecture.md)
