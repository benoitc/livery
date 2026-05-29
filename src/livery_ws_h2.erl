-module(livery_ws_h2).
-moduledoc """
`ws_transport` implementation over an HTTP/2 stream.

After an extended-CONNECT WebSocket handshake (RFC 8441), the WS
session exchanges frames as HTTP/2 DATA on the same stream. This
module maps the `ws_transport` callbacks onto the `h2` library:

- `send/2`   -> `h2:send_data/4` (no end_stream; frames keep flowing)
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

-spec send(handle(), iodata()) -> ok | {error, term()}.
send({Conn, StreamId}, IoData) ->
    h2:send_data(Conn, StreamId, iolist_to_binary(IoData), false).

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
