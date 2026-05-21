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

-export([upgrade/3]).

-export_type([handler_module/0, handler_opts/0]).

-type handler_module() :: module().
-type handler_opts() :: term().

-doc """
Upgrade the current request to a WebSocket session.

`HandlerMod` must implement the `ws_handler` behaviour. `Opts`
is opaque and forwarded as `HMod:init(Req, Opts)`'s second
argument by the `ws` library.

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
                    livery_resp:text(400,
                        iolist_to_binary([<<"bad ws upgrade: ">>,
                                          format_reason(Why)]));
                {error, Reason} ->
                    livery_resp:text(500,
                        iolist_to_binary([<<"ws upgrade failed: ">>,
                                          format_reason(Reason)]))
            end;
        false ->
            livery_resp:text(501,
                <<"WebSocket upgrade not supported on this protocol">>)
    end.

-spec adapter_supports_ws(module()) -> boolean().
adapter_supports_ws(livery_h1) -> true;
adapter_supports_ws(livery_h2) -> true;
adapter_supports_ws(livery_h3) -> true;
adapter_supports_ws(_)         -> false.

-spec format_reason(term()) -> iodata().
format_reason(B) when is_binary(B) -> B;
format_reason(A) when is_atom(A)   -> atom_to_binary(A);
format_reason(Other)               -> io_lib:format("~p", [Other]).
