-module(livery_ws).
-moduledoc """
WebSocket integration on top of the `ws` library.

A handler that wants to upgrade a request to WebSocket calls
`upgrade/3` inside its body. The function performs the
protocol-specific handshake by dispatching to the adapter's
`accept_ws/4` helper. The return value is a sentinel response
(`status = 101`, `body = taken_over`) that tells `livery:emit/3`
no further bytes need to be written: the stream/socket now belongs
to the `ws` session.

```erlang
my_ws_route(Req) ->
    livery_ws:upgrade(Req, my_chat_handler, #{}).
```

`my_chat_handler` is a module implementing the `ws_handler`
behaviour (defined by `erlang_ws`).

WebSocket runs over H1 (plain `Upgrade`), H2 (RFC 8441 extended
CONNECT, via `livery_ws_h2`), and H3 (RFC 9220 extended CONNECT,
via `livery_ws_h3`).
""".

-include("livery.hrl").

-export([upgrade/3, handshake_opts/1, deflate_opts/3]).

-export_type([handler_module/0, handler_opts/0]).

-type handler_module() :: module().
-type handler_opts() :: term().

-doc """
Upgrade the current request to a WebSocket session.

`HandlerMod` must implement the `ws_handler` behaviour. `Opts`
is a map forwarded as `HMod:init(Req, Opts)`'s second argument by
the `ws` library. Some keys are also interpreted by the handshake
(and left in `Opts`, so the handler still sees them):

- `subprotocols => [binary()]` drives subprotocol negotiation: the
  first of these the client also offers is echoed in the response
  `Sec-WebSocket-Protocol`, and a client offering none of them is
  rejected. Omit to skip negotiation.
- `idle_timeout => timeout()` overrides the session idle timeout
  (`infinity` never idle-closes). Omit for the `ws` default.
- `max_frame_size => pos_integer()` and
  `max_message_size => pos_integer()` bound a single frame and a
  reassembled fragmented message; a peer exceeding them is closed
  with `1009`. Omit for the `ws` defaults (16 MiB / 64 MiB).
- `compress => true` negotiates permessage-deflate (RFC 7692) when
  the client offers it; the session then runs compressed in both
  directions. Clients not offering it are served uncompressed.

When the session ends because the peer sent a close frame, the
handler's `terminate/2` receives `{remote, Code, Reason}` (or
`remote` for a bare close without a status code).

The handler's `Req` carries `peer => {IpAddress, Port}`, the client
address from the socket (H1), the h2 connection (H2), or the QUIC
connection (H3).

Returns a `#livery_resp{}` value:

- `status = 101, body = taken_over` on a successful handshake.
  The adapter owns nothing further on this stream after this
  point.
- `status = 400` with a textual body when the inbound headers do
  not satisfy RFC 6455.
- `status = 501` when the adapter does not support WebSocket
  upgrades (H1, H2, and H3 all do).
""".
-spec upgrade(livery_req:req(), handler_module(), handler_opts()) ->
    livery_resp:resp().
upgrade(Req, HandlerMod, Opts) ->
    Adapter = livery_req:adapter(Req),
    case adapter_supports_ws(Adapter) of
        true ->
            Stream = livery_req:stream(Req),
            case Adapter:accept_ws(Stream, Req, HandlerMod, Opts) of
                {ok, _SessionPid} ->
                    #livery_resp{status = 101, body = taken_over};
                {error, {bad_request, Why}} ->
                    livery_resp:text(
                        400,
                        iolist_to_binary([
                            <<"bad ws upgrade: ">>,
                            format_reason(Why)
                        ])
                    );
                {error, Reason} ->
                    livery_resp:text(
                        500,
                        iolist_to_binary([
                            <<"ws upgrade failed: ">>,
                            format_reason(Reason)
                        ])
                    )
            end;
        false ->
            livery_resp:text(
                501,
                <<"WebSocket upgrade not supported on this protocol">>
            )
    end.

-doc """
Split upgrade `Opts` into the two handshake option maps the adapters
need: `{ValidateOpts, AcceptOpts}`. `ValidateOpts` drives
`ws_hN_upgrade:validate_request/2` (subprotocol negotiation) and
`AcceptOpts` drives `ws:accept/6` (idle timeout). Both are `#{}` when the
respective key is absent, which makes the calls equivalent to the /1 and
/5 forms. Called by the H1/H2/H3 adapters.
""".
-spec handshake_opts(handler_opts()) -> {map(), map()}.
handshake_opts(Opts) when is_map(Opts) ->
    ValidateOpts =
        case maps:get(subprotocols, Opts, undefined) of
            [_ | _] = Subs -> #{required_subprotocols => Subs};
            _ -> #{}
        end,
    AcceptOpts0 =
        case maps:get(idle_timeout, Opts, undefined) of
            undefined -> #{};
            Timeout -> #{idle_timeout => Timeout}
        end,
    AcceptOpts =
        case parser_opts(Opts) of
            Empty when map_size(Empty) =:= 0 -> AcceptOpts0;
            ParserOpts -> AcceptOpts0#{parser_opts => ParserOpts}
        end,
    {ValidateOpts, AcceptOpts};
handshake_opts(_Opts) ->
    {#{}, #{}}.

%% Frame limits forwarded to the ws parser.
-spec parser_opts(map()) -> map().
parser_opts(Opts) ->
    P0 =
        case maps:get(max_frame_size, Opts, undefined) of
            undefined -> #{};
            MaxFrame -> #{max_frame => MaxFrame}
        end,
    case maps:get(max_message_size, Opts, undefined) of
        undefined -> P0;
        MaxMessage -> P0#{max_message => MaxMessage}
    end.

-doc """
Negotiate permessage-deflate for an upgrade when `Opts` carries
`compress => true` and the client offered it.

`Info` is the validated-request info from `ws_h1_upgrade` /
`ws_h2_upgrade` / `ws_h3_upgrade` (its `extensions` key holds the
client's raw offers). Returns extra response headers (the
`sec-websocket-extensions` acceptance, or none) and the accept opts
with `deflate` merged in. Called by the H1/H2/H3 adapters.
""".
-spec deflate_opts(map(), handler_opts(), map()) ->
    {[{binary(), binary()}], map()}.
deflate_opts(Info, Opts, AcceptOpts) when is_map(Opts) ->
    case maps:get(compress, Opts, false) of
        true ->
            case ws_deflate:negotiate(maps:get(extensions, Info, []), #{}) of
                {ok, RespExt, Negotiated} ->
                    {
                        [{<<"sec-websocket-extensions">>, iolist_to_binary(RespExt)}],
                        AcceptOpts#{deflate => Negotiated}
                    };
                ignore ->
                    {[], AcceptOpts}
            end;
        false ->
            {[], AcceptOpts}
    end;
deflate_opts(_Info, _Opts, AcceptOpts) ->
    {[], AcceptOpts}.

-spec adapter_supports_ws(module()) -> boolean().
adapter_supports_ws(livery_h1) -> true;
adapter_supports_ws(livery_h2) -> true;
adapter_supports_ws(livery_h3) -> true;
adapter_supports_ws(_) -> false.

-spec format_reason(term()) -> iodata().
format_reason(B) when is_binary(B) -> B;
format_reason(A) when is_atom(A) -> atom_to_binary(A);
format_reason(Other) -> io_lib:format("~p", [Other]).
