-module(livery_wt).
-moduledoc """
WebTransport integration on top of the `webtransport` library.

A handler that wants to accept a WebTransport session (initiated
by an HTTP extended CONNECT with `:protocol = webtransport`) calls
`upgrade/3`. The function dispatches to the adapter's `accept_wt/4`
helper, which reconstructs the CONNECT pseudo-headers and calls
`webtransport:accept/4`. On success the stream/session belongs to
the `webtransport` session process and `upgrade/3` returns the
`taken_over` sentinel response.

```erlang
my_wt_route(Req) ->
    livery_wt:upgrade(Req, my_wt_handler, #{}).
```

`my_wt_handler` implements the `webtransport_handler` behaviour
(from `erlang-webtransport`).

WebTransport runs only over H2 (extended CONNECT, RFC 9220-style)
and H3. Calling `upgrade/3` on H1 returns `501 Not Implemented`.

The listener must advertise the WebTransport settings. Merge
`webtransport:h3_settings/0` (or `h2_settings/0`) into the listener
options so the adapter forwards the H3/H2 SETTINGS, datagram
support, and WT stream routing to the wire library:

```erlang
Opts = maps:merge(webtransport:h3_settings(), #{
    cert => Cert, key => Key, stack => Stack,
    handler => fun(Req) -> livery_wt:upgrade(Req, my_handler, #{}) end
}),
livery_h3:start(Opts).
```

End-to-end bidi-stream and datagram echo over a real session is
covered by `livery_wt_SUITE` (needs `webtransport` >= 0.2.3, where
`accept/4` works from Livery's per-request worker process).
""".

-include("livery.hrl").

-export([upgrade/3]).

-export_type([handler_module/0, handler_opts/0]).

-type handler_module() :: module().
-type handler_opts() :: term().

-doc """
Accept a WebTransport session on the current request.

`HandlerMod` implements `webtransport_handler`. Returns the
`taken_over` sentinel on success, `501` on H1, or `4xx/5xx` text
when the handshake is rejected.
""".
-spec upgrade(livery_req:req(), handler_module(), handler_opts()) ->
    livery_resp:resp().
upgrade(Req, HandlerMod, Opts) ->
    Adapter = livery_req:adapter(Req),
    case adapter_transport(Adapter) of
        undefined ->
            livery_resp:text(
                501,
                <<"WebTransport not supported on this protocol">>
            );
        Transport ->
            case Adapter:accept_wt(Transport, Req, HandlerMod, Opts) of
                {ok, _Session} ->
                    #livery_resp{status = 200, body = taken_over};
                {error, not_connect_method} ->
                    livery_resp:text(400, <<"not a CONNECT request">>);
                {error, {rejected, Status}} ->
                    livery_resp:text(Status, <<"webtransport rejected">>);
                {error, Reason} ->
                    livery_resp:text(
                        500,
                        iolist_to_binary([
                            <<"webtransport upgrade failed: ">>,
                            format_reason(Reason)
                        ])
                    )
            end
    end.

-spec adapter_transport(module()) -> h2 | h3 | undefined.
adapter_transport(livery_h2) -> h2;
adapter_transport(livery_h3) -> h3;
adapter_transport(_) -> undefined.

-spec format_reason(term()) -> iodata().
format_reason(B) when is_binary(B) -> B;
format_reason(A) when is_atom(A) -> atom_to_binary(A);
format_reason(Other) -> io_lib:format("~p", [Other]).
