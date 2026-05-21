-module(livery_adapter).
-moduledoc """
Internal behaviour implemented by `livery_h1`, `livery_h2`,
`livery_h3`, and `livery_test_adapter`.

Adapters translate engine events into `#livery_req{}` values and
drive the response back onto the wire. They own no state machines;
framing, header compression, flow control, and TLS belong upstream
in `h1`, `h2`, `quic`, and `ws`.

Each adapter spawns a `livery_req_proc` for every incoming request
and routes body/trailers/eof messages to that pid. Once the
handler returns a `#livery_resp{}`, the core walks the body
variant and calls back into the adapter via the callbacks defined
here.

## Callbacks

- `start(Name, ListenSpec, Opts) -> {ok, Listener} | {error, _}` —
  start a listener for this adapter.
- `stop(Listener) -> ok` — stop a listener cleanly.
- `send_headers(Stream, Status, Headers, SendOpts) -> SendResult` —
  emit response headers. `SendOpts` may carry
  `end_stream => true` when the response has no body.
- `send_data(Stream, IoData, SendOpts) -> SendResult` — emit body
  bytes. `end_stream => true` closes the send half;
  `flush => true` hints the adapter to push immediately rather
  than batch.
- `send_trailers(Stream, Trailers) -> SendResult` — emit trailers
  (and implicitly close the send half).
- `reset(Stream, Reason) -> ok` — reset a stream with a
  protocol-specific reason.
- `peer_info(Stream) -> peer_info()` — return peer/TLS info for a
  stream.
- `capabilities(Listener) -> capabilities()` — return the
  capability bitmap of a listener.
""".

-export_type([
    listener/0,
    listen_spec/0,
    opts/0,
    stream/0,
    send_opts/0,
    capabilities/0,
    peer_info/0,
    reset_reason/0,
    send_result/0
]).

-type listener() :: term().
-type listen_spec() :: term().
-type opts() :: map().
-type stream() :: term().

-type send_opts() :: #{
    end_stream => boolean(),
    flush => boolean()
}.

-type capabilities() :: #{
    trailers => boolean(),
    extended_connect => boolean(),
    datagrams => boolean(),
    capsules => boolean()
}.

-type peer_info() :: #{
    peer => {inet:ip_address(), inet:port_number()} | undefined,
    tls => undefined | map(),
    alpn => binary() | undefined
}.

-type reset_reason() :: term().

-type send_result() :: ok | {error, closed | flow | term()}.

-callback start(Name :: atom(), listen_spec(), opts()) ->
    {ok, listener()} | {error, term()}.

-callback stop(listener()) -> ok.

-callback send_headers(
    stream(),
    100..599,
    [{binary(), binary()}],
    send_opts()
) ->
    send_result().

-callback send_data(stream(), iodata(), send_opts()) -> send_result().

-callback send_trailers(stream(), [{binary(), binary()}]) -> send_result().

-callback reset(stream(), reset_reason()) -> ok.

-callback peer_info(stream()) -> peer_info().

-callback capabilities(listener()) -> capabilities().
