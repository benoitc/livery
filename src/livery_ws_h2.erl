-module(livery_ws_h2).
-moduledoc """
`ws_transport` implementation over an HTTP/2 stream.

After an extended-CONNECT WebSocket handshake (RFC 8441), the WS
session exchanges frames as HTTP/2 DATA on the same stream. This
module maps the `ws_transport` callbacks onto the `h2` library:

- `send/2`   -> `h2:send_data/5` (no end_stream; frames keep flowing).
  It waits for the peer's flow window, up to 30 seconds, as
  `livery_ws_h3` waits for quic's send queue, so a message larger than
  h2's send buffer still goes out.
- `controlling_process/2` -> `h2:set_stream_handler/4`, so the
  session process receives the stream's DATA events
- `classify/2` turns `{h2, Conn, {data, ...}}` into `{ws_data, ...}`
  and stream resets into `{ws_closed, ...}`

The handle is `{Conn, StreamId}`.
""".
-behaviour(ws_transport).

-export([
    send/2,
    activate/1,
    close/1,
    controlling_process/2,
    classify/2,
    peername/1
]).

-type handle() :: {h2:connection(), h2:stream_id()}.

%% How long a send may wait for the peer's flow window, as in livery_ws_h3.
-define(SEND_TIMEOUT, 30000).

-spec send(handle(), iodata()) -> ok | {error, term()}.
send({Conn, StreamId}, IoData) ->
    case h2:send_data(Conn, StreamId, iolist_to_binary(IoData), false, #{block => ?SEND_TIMEOUT}) of
        {error, timeout} -> {error, send_timeout};
        Other -> Other
    end.

-spec activate(handle()) -> ok.
activate(_Handle) ->
    %% h2 delivers DATA to whichever pid is the registered stream
    %% handler; there is no per-batch pull to arm.
    ok.

-spec close(handle()) -> ok.
close({Conn, StreamId}) ->
    _ =
        try
            h2:send_data(Conn, StreamId, <<>>, true)
        catch
            _:_ -> ok
        end,
    ok.

-spec controlling_process(handle(), pid()) -> ok | {error, term()}.
controlling_process({Conn, StreamId}, Pid) ->
    case h2:set_stream_handler(Conn, StreamId, Pid, #{drain_buffer => false}) of
        ok -> ok;
        {ok, _} -> ok;
        {error, _} = E -> E
    end.

-spec classify(term(), handle()) ->
    {ws_data, handle(), binary()}
    | {ws_closed, handle()}
    | {ws_error, handle(), term()}
    | ignore.
classify({h2, Conn, {data, StreamId, Bin, _Fin}}, {Conn, StreamId} = H) ->
    {ws_data, H, Bin};
classify({h2, Conn, {stream_reset, StreamId, Reason}}, {Conn, StreamId} = H) ->
    {ws_error, H, Reason};
classify({h2, Conn, {trailers, StreamId, _}}, {Conn, StreamId} = H) ->
    {ws_closed, H};
classify({h2, Conn, {closed, _}}, {Conn, _} = H) ->
    {ws_closed, H};
classify(_Msg, _Handle) ->
    ignore.

-spec peername(handle()) -> {error, not_supported}.
peername(_Handle) ->
    {error, not_supported}.
