-module(livery_ws_h3).
-moduledoc """
`ws_transport` implementation over an HTTP/3 (QUIC) stream.

After an extended-CONNECT WebSocket handshake (RFC 9220), the WS
session exchanges frames as HTTP/3 DATA on the same stream. This
module maps the `ws_transport` callbacks onto the `quic_h3`
library:

- `send/2`   -> `quic_h3:send_data/4`
- `controlling_process/2` -> `quic_h3:set_stream_handler/4`
- `classify/2` turns `{quic_h3, Conn, {data, ...}}` into
  `{ws_data, ...}` and resets into `{ws_error, ...}`

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

-type handle() :: {pid(), non_neg_integer()}.

-spec send(handle(), iodata()) -> ok | {error, term()}.
send({Conn, StreamId}, IoData) ->
    quic_h3:send_data(Conn, StreamId, iolist_to_binary(IoData), false).

-spec activate(handle()) -> ok.
activate(_Handle) ->
    ok.

-spec close(handle()) -> ok.
close({Conn, StreamId}) ->
    _ =
        try
            quic_h3:send_data(Conn, StreamId, <<>>, true)
        catch
            _:_ -> ok
        end,
    ok.

-spec controlling_process(handle(), pid()) -> ok | {error, term()}.
controlling_process({Conn, StreamId}, Pid) ->
    case
        quic_h3:set_stream_handler(
            Conn,
            StreamId,
            Pid,
            #{drain_buffer => false}
        )
    of
        ok -> ok;
        {ok, _} -> ok;
        {error, _} = E -> E
    end.

-spec classify(term(), handle()) ->
    {ws_data, handle(), binary()}
    | {ws_closed, handle()}
    | {ws_error, handle(), term()}
    | ignore.
classify({quic_h3, Conn, {data, StreamId, Bin, _Fin}}, {Conn, StreamId} = H) ->
    {ws_data, H, Bin};
classify({quic_h3, Conn, {stream_reset, StreamId, Reason}}, {Conn, StreamId} = H) ->
    {ws_error, H, Reason};
classify({quic_h3, Conn, {trailers, StreamId, _}}, {Conn, StreamId} = H) ->
    {ws_closed, H};
classify({quic_h3, Conn, {stream_end, StreamId}}, {Conn, StreamId} = H) ->
    {ws_closed, H};
classify(_Msg, _Handle) ->
    ignore.

-spec peername(handle()) -> {error, not_supported}.
peername(_Handle) ->
    {error, not_supported}.
