%% @doc HTTP/3 connection handler for livery server.
%%
%% Handles HTTP/3 connections over QUIC, including:
%% - Control stream setup
%% - QPACK encoder/decoder streams
%% - Request stream multiplexing
%% - HEADERS and DATA frame processing
-module(livery_h3).

-behaviour(gen_statem).

-include("livery.hrl").

-export([
    %% API
    start_link/3,
    send_response/5,
    send_headers/4,
    send_data/4,
    send_trailers/3,
    close/2,
    %% WebSocket API (RFC 9220)
    send_ws_frame/3,
    send_ws_text/3,
    send_ws_binary/3,
    send_ws_ping/2,
    send_ws_ping/3,
    send_ws_pong/3,
    send_ws_close/2,
    send_ws_close/3,
    send_ws_close/4,
    %% gen_statem callbacks
    callback_mode/0,
    init/1,
    handle_event/4,
    terminate/3
]).

%% HTTP/3 frame types (RFC 9114)
-define(H3_DATA,          16#00).
-define(H3_HEADERS,       16#01).
-define(H3_CANCEL_PUSH,   16#03).
-define(H3_SETTINGS,      16#04).
-define(H3_PUSH_PROMISE,  16#05).
-define(H3_GOAWAY,        16#07).
-define(H3_MAX_PUSH_ID,   16#0D).

%% HTTP/3 unidirectional stream types
-define(H3_STREAM_CONTROL,       16#00).
-define(H3_STREAM_PUSH,          16#01).
-define(H3_STREAM_QPACK_ENCODER, 16#02).
-define(H3_STREAM_QPACK_DECODER, 16#03).

%% Default max field section size per RFC 9114
%% Must match the value in livery_h3_frame:default_settings()
-define(DEFAULT_MAX_FIELD_SECTION_SIZE, 65536).

-record(h3_state, {
    quic_conn :: reference() | undefined,
    handler :: module(),
    handler_opts :: term(),
    %% Peer address (from QUIC connection)
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    %% Streams
    streams = #{} :: #{non_neg_integer() => stream_state()},
    uni_streams = #{} :: #{non_neg_integer() => uni_stream_info()},
    %% Control streams (our side)
    control_stream :: non_neg_integer() | undefined,
    qpack_encoder_stream :: non_neg_integer() | undefined,
    qpack_decoder_stream :: non_neg_integer() | undefined,
    %% Control streams (peer side)
    peer_control_stream :: non_neg_integer() | undefined,
    peer_qpack_encoder :: non_neg_integer() | undefined,
    peer_qpack_decoder :: non_neg_integer() | undefined,
    %% State tracking
    settings_sent = false :: boolean(),
    settings_received = false :: boolean(),
    %% Peer settings - limits we must enforce
    peer_max_field_section_size = ?DEFAULT_MAX_FIELD_SECTION_SIZE :: non_neg_integer(),
    %% Our settings - limits peer must enforce (we validate incoming)
    max_field_section_size = ?DEFAULT_MAX_FIELD_SECTION_SIZE :: non_neg_integer(),
    %% Extended CONNECT (RFC 9220) - peer's advertised support
    peer_enable_connect_protocol = 0 :: non_neg_integer(),
    %% QPACK state
    qpack_encoder :: livery_qpack:state(),
    qpack_decoder :: livery_qpack:state()
}).

-record(stream_state, {
    buffer = <<>> :: binary(),
    headers = [] :: [{binary(), binary()}],
    headers_received = false :: boolean(),
    body = [] :: iolist(),  %% Use iolist for O(1) prepend
    data_received = false :: boolean(),
    trailers = [] :: [{binary(), binary()}],
    trailers_received = false :: boolean(),
    fin_received = false :: boolean(),
    dispatched = false :: boolean(),  %% Track if request was dispatched
    handler_state :: term(),
    %% WebSocket over HTTP/3 (RFC 9220)
    mode = normal :: normal | websocket,
    ws_buffer = <<>> :: binary()
}).

-record(uni_stream_info, {
    type :: control | push | qpack_encoder | qpack_decoder | unknown,
    buffer = <<>> :: binary()
}).

-type stream_state() :: #stream_state{}.
-type uni_stream_info() :: #uni_stream_info{}.

%%====================================================================
%% API
%%====================================================================

%% @doc Start HTTP/3 connection handler.
-spec start_link(reference(), module(), term()) -> {ok, pid()} | {error, term()}.
start_link(QuicConn, Handler, HandlerOpts) ->
    gen_statem:start_link(?MODULE, {QuicConn, Handler, HandlerOpts}, []).

%% @doc Send a complete HTTP/3 response on a stream.
-spec send_response(pid(), non_neg_integer(), integer(), [{binary(), binary()}], binary()) -> ok | {error, term()}.
send_response(Pid, StreamId, Status, Headers, Body) ->
    gen_statem:call(Pid, {send_response, StreamId, Status, Headers, Body}).

%% @doc Send HTTP/3 response headers on a stream.
-spec send_headers(pid(), non_neg_integer(), integer(), [{binary(), binary()}]) -> ok | {error, term()}.
send_headers(Pid, StreamId, Status, Headers) ->
    gen_statem:call(Pid, {send_headers, StreamId, Status, Headers, false}).

%% @doc Send HTTP/3 data on a stream.
-spec send_data(pid(), non_neg_integer(), binary(), boolean()) -> ok | {error, term()}.
send_data(Pid, StreamId, Data, Fin) ->
    gen_statem:call(Pid, {send_data, StreamId, Data, Fin}).

%% @doc Send HTTP/3 trailers (HEADERS frame with END_STREAM) on a stream.
%% Trailers must be sent after the body. They complete the stream.
-spec send_trailers(pid(), non_neg_integer(), [{binary(), binary()}]) -> ok | {error, term()}.
send_trailers(Pid, StreamId, Trailers) ->
    gen_statem:call(Pid, {send_trailers, StreamId, Trailers}).

%% @doc Close the HTTP/3 connection.
-spec close(pid(), term()) -> ok.
close(Pid, Reason) ->
    gen_statem:cast(Pid, {close, Reason}).

%%--------------------------------------------------------------------
%% WebSocket API (RFC 9220)
%%--------------------------------------------------------------------

%% @doc Send a WebSocket frame on a stream.
%% Frame can be {text, binary()}, {binary, binary()}, {ping, binary()}, etc.
-spec send_ws_frame(pid(), non_neg_integer(), livery_ws:frame()) -> ok | {error, term()}.
send_ws_frame(Pid, StreamId, Frame) ->
    gen_statem:call(Pid, {send_ws_frame, StreamId, Frame}).

%% @doc Send a WebSocket text frame.
-spec send_ws_text(pid(), non_neg_integer(), binary()) -> ok | {error, term()}.
send_ws_text(Pid, StreamId, Text) ->
    send_ws_frame(Pid, StreamId, {text, Text}).

%% @doc Send a WebSocket binary frame.
-spec send_ws_binary(pid(), non_neg_integer(), binary()) -> ok | {error, term()}.
send_ws_binary(Pid, StreamId, Data) ->
    send_ws_frame(Pid, StreamId, {binary, Data}).

%% @doc Send a WebSocket ping frame with no payload.
-spec send_ws_ping(pid(), non_neg_integer()) -> ok | {error, term()}.
send_ws_ping(Pid, StreamId) ->
    send_ws_frame(Pid, StreamId, {ping, <<>>}).

%% @doc Send a WebSocket ping frame with payload.
-spec send_ws_ping(pid(), non_neg_integer(), binary()) -> ok | {error, term()}.
send_ws_ping(Pid, StreamId, Payload) ->
    send_ws_frame(Pid, StreamId, {ping, Payload}).

%% @doc Send a WebSocket pong frame.
-spec send_ws_pong(pid(), non_neg_integer(), binary()) -> ok | {error, term()}.
send_ws_pong(Pid, StreamId, Payload) ->
    send_ws_frame(Pid, StreamId, {pong, Payload}).

%% @doc Send a WebSocket close frame with status 1000 (normal).
-spec send_ws_close(pid(), non_neg_integer()) -> ok | {error, term()}.
send_ws_close(Pid, StreamId) ->
    send_ws_close(Pid, StreamId, 1000).

%% @doc Send a WebSocket close frame with status code.
-spec send_ws_close(pid(), non_neg_integer(), non_neg_integer()) -> ok | {error, term()}.
send_ws_close(Pid, StreamId, Code) ->
    gen_statem:call(Pid, {send_ws_close, StreamId, Code, <<>>}).

%% @doc Send a WebSocket close frame with status code and reason.
-spec send_ws_close(pid(), non_neg_integer(), non_neg_integer(), binary()) -> ok | {error, term()}.
send_ws_close(Pid, StreamId, Code, Reason) ->
    gen_statem:call(Pid, {send_ws_close, StreamId, Code, Reason}).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

-spec callback_mode() -> gen_statem:callback_mode().
callback_mode() -> handle_event_function.

-spec init({reference(), module(), term()}) -> gen_statem:init_result(atom()).
init({QuicConn, Handler, HandlerOpts}) ->
    %% Initialize QPACK with dynamic table support
    %% Default max size is 4096 bytes per RFC 9204
    QpackOpts = #{max_dynamic_size => 4096},
    State = #h3_state{
        quic_conn = QuicConn,
        handler = Handler,
        handler_opts = HandlerOpts,
        qpack_encoder = livery_qpack:init(QpackOpts),
        qpack_decoder = livery_qpack:init(QpackOpts)
    },
    %% Wait for QUIC connection to be established before setting up H3 streams
    %% The {connected, Info} message will trigger setup_h3_streams
    {ok, connecting, State}.

-spec handle_event(gen_statem:event_type(), term(), atom(), #h3_state{}) ->
    gen_statem:event_handler_result(atom()).
handle_event({call, From}, {send_response, StreamId, Status, Headers, Body}, _StateName, State) ->
    AllHeaders = [{<<":status">>, integer_to_binary(Status)} | Headers],
    HasBody = Body =/= <<>> andalso Body =/= [],
    Fin = not HasBody,
    case do_send_headers(StreamId, AllHeaders, Fin, State) of
        {ok, State1} when HasBody ->
            case do_send_data(StreamId, Body, true, State1) of
                {ok, State2} ->
                    {keep_state, State2, [{reply, From, ok}]};
                {error, Reason} ->
                    {keep_state, State1, [{reply, From, {error, Reason}}]}
            end;
        {ok, State1} ->
            {keep_state, State1, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;

handle_event({call, From}, {send_headers, StreamId, Status, Headers, Fin}, _StateName, State) ->
    AllHeaders = [{<<":status">>, integer_to_binary(Status)} | Headers],
    case do_send_headers(StreamId, AllHeaders, Fin, State) of
        {ok, State1} ->
            {keep_state, State1, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;

handle_event({call, From}, {send_data, StreamId, Data, Fin}, _StateName, State) ->
    case do_send_data(StreamId, Data, Fin, State) of
        {ok, State1} ->
            {keep_state, State1, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;

handle_event({call, From}, {send_trailers, StreamId, Trailers}, _StateName, State) ->
    %% Trailers are sent as a HEADERS frame with FIN=true
    case do_send_headers(StreamId, Trailers, true, State) of
        {ok, State1} ->
            {keep_state, State1, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;

handle_event({call, From}, {send_ws_frame, StreamId, Frame}, _StateName,
             #h3_state{quic_conn = QuicConn} = State) ->
    %% Send WebSocket frame wrapped in HTTP/3 DATA frame
    WsFrame = encode_ws_frame(Frame),
    DataFrame = livery_h3_frame:encode_data(WsFrame),
    case quic:send_data(QuicConn, StreamId, DataFrame, false) of
        ok ->
            {keep_state, State, [{reply, From, ok}]};
        {error, Reason} ->
            {keep_state, State, [{reply, From, {error, Reason}}]}
    end;

handle_event({call, From}, {send_ws_close, StreamId, Code, Reason}, _StateName,
             #h3_state{quic_conn = QuicConn} = State) ->
    %% Send WebSocket close frame and finish the stream
    CloseFrame = case Reason of
        <<>> -> livery_ws:encode_close(Code);
        _ -> livery_ws:encode_close(Code, Reason)
    end,
    DataFrame = livery_h3_frame:encode_data(CloseFrame),
    case quic:send_data(QuicConn, StreamId, DataFrame, true) of
        ok ->
            {keep_state, State, [{reply, From, ok}]};
        {error, Err} ->
            {keep_state, State, [{reply, From, {error, Err}}]}
    end;

handle_event(cast, {close, Reason}, _StateName, #h3_state{quic_conn = QuicConn} = State) ->
    %% Send GOAWAY frame
    GoawayFrame = livery_h3_frame:encode_goaway(0),
    case State#h3_state.control_stream of
        undefined -> ok;
        ControlStream ->
            quic:send_data(QuicConn, ControlStream, GoawayFrame, false)
    end,
    quic:close(QuicConn, Reason),
    {stop, normal, State};

handle_event(info, {quic, QuicConn, {connected, _Info}},
             connecting, #h3_state{quic_conn = QuicConn} = State) ->
    error_logger:info_msg("[H3] Received 'connected' event, setting up H3 streams~n"),
    %% Get peer address from QUIC connection
    Peer = case quic:peername(QuicConn) of
        {ok, PeerAddr} -> PeerAddr;
        {error, _} -> undefined
    end,
    %% QUIC connection fully established - now set up HTTP/3 control streams
    State1 = setup_h3_streams(State#h3_state{peer = Peer}),
    {next_state, connected, State1};

handle_event(info, {quic, QuicConn, {connected, _Info}},
             connected, #h3_state{quic_conn = QuicConn} = State) ->
    %% Already connected, ignore duplicate
    {keep_state, State};

handle_event(info, {quic, QuicConn, {stream_data, StreamId, Data, Fin}},
             _StateName, #h3_state{quic_conn = QuicConn} = State) ->
    %% Check if this is a unidirectional stream
    case is_unidirectional_stream(StreamId) of
        true ->
            State1 = process_uni_stream_data(StreamId, Data, Fin, State),
            {keep_state, State1};
        false ->
            State1 = process_bidi_stream_data(StreamId, Data, Fin, State),
            {keep_state, State1}
    end;

handle_event(info, {quic, QuicConn, {stream_reset, StreamId, _ErrorCode}},
             _StateName, #h3_state{quic_conn = QuicConn, streams = Streams} = State) ->
    %% Stream was reset by peer
    State1 = State#h3_state{streams = maps:remove(StreamId, Streams)},
    {keep_state, State1};

handle_event(info, {quic, QuicConn, {closed, _Reason}},
             _StateName, #h3_state{quic_conn = QuicConn} = State) ->
    {stop, normal, State};

handle_event(info, {quic, QuicConn, {transport_error, _Code, _Reason}},
             _StateName, #h3_state{quic_conn = QuicConn} = State) ->
    {stop, normal, State};

handle_event(info, {quic, QuicConn, {stream_opened, StreamId}},
             _StateName, #h3_state{quic_conn = QuicConn, streams = Streams} = State) ->
    %% New stream opened by peer - initialize stream state
    NewStreams = maps:put(StreamId, #stream_state{}, Streams),
    {keep_state, State#h3_state{streams = NewStreams}};

handle_event(info, Msg, StateName, State) ->
    error_logger:info_msg("[H3] Unhandled message in state ~p: ~p~n", [StateName, Msg]),
    {keep_state, State}.

-spec terminate(term(), atom(), #h3_state{}) -> ok.
terminate(_Reason, _StateName, #h3_state{quic_conn = QuicConn}) ->
    case QuicConn of
        undefined -> ok;
        _ -> catch quic:close(QuicConn, shutdown)
    end,
    ok.

%%====================================================================
%% Internal - Stream setup
%%====================================================================

setup_h3_streams(#h3_state{quic_conn = QuicConn} = State) ->
    %% Open control stream (unidirectional)
    case quic:open_unidirectional_stream(QuicConn) of
        {ok, ControlStreamId} ->
            %% Send stream type (0x00 = control)
            StreamType = livery_h3_frame:encode_varint(?H3_STREAM_CONTROL),
            %% Send SETTINGS frame
            SettingsFrame = livery_h3_frame:encode_settings(livery_h3_frame:default_settings()),
            quic:send_data(QuicConn, ControlStreamId, <<StreamType/binary, SettingsFrame/binary>>, false),

            %% Open QPACK encoder stream
            case quic:open_unidirectional_stream(QuicConn) of
                {ok, QpackEncStreamId} ->
                    EncType = livery_h3_frame:encode_varint(?H3_STREAM_QPACK_ENCODER),
                    quic:send_data(QuicConn, QpackEncStreamId, EncType, false),

                    %% Open QPACK decoder stream
                    case quic:open_unidirectional_stream(QuicConn) of
                        {ok, QpackDecStreamId} ->
                            DecType = livery_h3_frame:encode_varint(?H3_STREAM_QPACK_DECODER),
                            quic:send_data(QuicConn, QpackDecStreamId, DecType, false),
                            State#h3_state{
                                control_stream = ControlStreamId,
                                qpack_encoder_stream = QpackEncStreamId,
                                qpack_decoder_stream = QpackDecStreamId,
                                settings_sent = true
                            };
                        _ ->
                            State#h3_state{
                                control_stream = ControlStreamId,
                                qpack_encoder_stream = QpackEncStreamId,
                                settings_sent = true
                            }
                    end;
                _ ->
                    State#h3_state{
                        control_stream = ControlStreamId,
                        settings_sent = true
                    }
            end;
        _ ->
            State
    end.

%%====================================================================
%% Internal - Send operations
%%====================================================================

do_send_headers(StreamId, Headers, Fin, #h3_state{quic_conn = QuicConn, qpack_encoder = Encoder,
                                                  qpack_encoder_stream = EncStream} = State) ->
    %% Encode headers using QPACK
    {EncodedHeaders, Encoder1} = livery_qpack:encode(Headers, Encoder),

    %% Send any pending encoder instructions on the encoder stream
    EncoderInstructions = livery_qpack:get_encoder_instructions(Encoder1),
    Encoder2 = case byte_size(EncoderInstructions) > 0 andalso EncStream =/= undefined of
        true ->
            quic:send_data(QuicConn, EncStream, EncoderInstructions, false),
            livery_qpack:clear_encoder_instructions(Encoder1);
        false ->
            Encoder1
    end,

    %% Wrap in HTTP/3 HEADERS frame
    Frame = livery_h3_frame:encode_headers(EncodedHeaders),
    %% Send on the QUIC stream
    case quic:send_data(QuicConn, StreamId, Frame, Fin) of
        ok ->
            {ok, State#h3_state{qpack_encoder = Encoder2}};
        {error, _} = Error ->
            Error
    end.

do_send_data(StreamId, Data, Fin, #h3_state{quic_conn = QuicConn} = State) ->
    %% Wrap in HTTP/3 DATA frame
    DataBin = iolist_to_binary(Data),
    Frame = livery_h3_frame:encode_data(DataBin),
    %% Send on the QUIC stream
    case quic:send_data(QuicConn, StreamId, Frame, Fin) of
        ok ->
            {ok, State};
        {error, _} = Error ->
            Error
    end.

%%====================================================================
%% Internal - Receive operations
%%====================================================================

%% Check if stream is unidirectional based on stream ID
%% QUIC stream IDs: low 2 bits indicate type
%% 00 = client-initiated bidirectional
%% 01 = server-initiated bidirectional
%% 10 = client-initiated unidirectional
%% 11 = server-initiated unidirectional
is_unidirectional_stream(StreamId) ->
    (StreamId band 2) =:= 2.

process_uni_stream_data(StreamId, Data, Fin, #h3_state{uni_streams = UniStreams} = State) ->
    StreamInfo = maps:get(StreamId, UniStreams, #uni_stream_info{type = unknown}),
    Buffer = <<(StreamInfo#uni_stream_info.buffer)/binary, Data/binary>>,

    case StreamInfo#uni_stream_info.type of
        unknown ->
            %% First data on this stream - parse stream type
            case livery_h3_frame:decode_varint(Buffer) of
                {ok, Type, Rest} ->
                    StreamType = stream_type_atom(Type),
                    NewInfo = #uni_stream_info{type = StreamType, buffer = Rest},
                    State1 = register_peer_stream(StreamId, StreamType, State),
                    State2 = State1#h3_state{uni_streams = maps:put(StreamId, NewInfo, UniStreams)},
                    %% Process any remaining data
                    process_uni_stream_by_type(StreamId, StreamType, Rest, Fin, State2);
                incomplete ->
                    %% Need more data
                    NewInfo = StreamInfo#uni_stream_info{buffer = Buffer},
                    State#h3_state{uni_streams = maps:put(StreamId, NewInfo, UniStreams)}
            end;
        Type ->
            %% Already know the type, process data
            process_uni_stream_by_type(StreamId, Type, Buffer, Fin, State)
    end.

stream_type_atom(?H3_STREAM_CONTROL) -> control;
stream_type_atom(?H3_STREAM_PUSH) -> push;
stream_type_atom(?H3_STREAM_QPACK_ENCODER) -> qpack_encoder;
stream_type_atom(?H3_STREAM_QPACK_DECODER) -> qpack_decoder;
stream_type_atom(_) -> unknown.

register_peer_stream(StreamId, control, State) ->
    State#h3_state{peer_control_stream = StreamId};
register_peer_stream(StreamId, qpack_encoder, State) ->
    State#h3_state{peer_qpack_encoder = StreamId};
register_peer_stream(StreamId, qpack_decoder, State) ->
    State#h3_state{peer_qpack_decoder = StreamId};
register_peer_stream(_StreamId, _Type, State) ->
    State.

process_uni_stream_by_type(StreamId, control, Data, _Fin, #h3_state{uni_streams = UniStreams} = State) ->
    %% Control stream carries HTTP/3 frames (SETTINGS, GOAWAY, etc.)
    {Messages, Rest} = parse_control_frames(Data, []),
    NewInfo = #uni_stream_info{type = control, buffer = Rest},
    %% Process settings from received frames
    State1 = apply_peer_settings(Messages, State),
    %% Only set settings_received if we actually got a SETTINGS frame
    HasSettings = lists:any(fun({settings, _}) -> true; (_) -> false end, Messages),
    State1#h3_state{
        uni_streams = maps:put(StreamId, NewInfo, UniStreams),
        settings_received = HasSettings orelse State#h3_state.settings_received
    };

process_uni_stream_by_type(StreamId, qpack_encoder, Data, _Fin,
                          #h3_state{uni_streams = UniStreams, qpack_decoder = Decoder} = State) ->
    %% QPACK encoder stream - instructions for dynamic table
    %% Process instructions to update decoder's dynamic table
    case livery_qpack:process_encoder_instructions(Data, Decoder) of
        {ok, NewDecoder} ->
            NewInfo = #uni_stream_info{type = qpack_encoder, buffer = <<>>},
            State#h3_state{
                uni_streams = maps:put(StreamId, NewInfo, UniStreams),
                qpack_decoder = NewDecoder
            };
        {error, _Reason} ->
            %% Invalid encoder instruction - buffer and continue
            NewInfo = #uni_stream_info{type = qpack_encoder, buffer = Data},
            State#h3_state{uni_streams = maps:put(StreamId, NewInfo, UniStreams)}
    end;

process_uni_stream_by_type(StreamId, qpack_decoder, Data, _Fin,
                          #h3_state{uni_streams = UniStreams, qpack_encoder = Encoder} = State) ->
    %% QPACK decoder stream - acknowledgments from peer
    %% Process instructions to update encoder's known received count
    case livery_qpack:process_decoder_instructions(Data, Encoder) of
        {ok, NewEncoder} ->
            NewInfo = #uni_stream_info{type = qpack_decoder, buffer = <<>>},
            State#h3_state{
                uni_streams = maps:put(StreamId, NewInfo, UniStreams),
                qpack_encoder = NewEncoder
            };
        {error, _Reason} ->
            NewInfo = #uni_stream_info{type = qpack_decoder, buffer = Data},
            State#h3_state{uni_streams = maps:put(StreamId, NewInfo, UniStreams)}
    end;

process_uni_stream_by_type(StreamId, _Type, _Data, _Fin, #h3_state{uni_streams = UniStreams} = State) ->
    %% Unknown or push stream - ignore
    NewInfo = #uni_stream_info{type = unknown, buffer = <<>>},
    State#h3_state{uni_streams = maps:put(StreamId, NewInfo, UniStreams)}.

parse_control_frames(Data, Acc) ->
    case livery_h3_frame:decode(Data) of
        {ok, Frame, Rest} ->
            parse_control_frames(Rest, [Frame | Acc]);
        _ ->
            {lists:reverse(Acc), Data}
    end.

%% @doc Apply peer settings from received SETTINGS frames.
apply_peer_settings([], State) ->
    State;
apply_peer_settings([{settings, Settings} | Rest], State) ->
    %% Extract max_field_section_size if present
    MaxFieldSize = maps:get(max_field_section_size, Settings,
                            State#h3_state.peer_max_field_section_size),
    %% Extract enable_connect_protocol (RFC 9220)
    EnableConnect = maps:get(enable_connect_protocol, Settings,
                             State#h3_state.peer_enable_connect_protocol),
    State1 = State#h3_state{
        peer_max_field_section_size = MaxFieldSize,
        peer_enable_connect_protocol = EnableConnect
    },
    apply_peer_settings(Rest, State1);
apply_peer_settings([_ | Rest], State) ->
    %% Skip non-settings frames (GOAWAY, etc.)
    apply_peer_settings(Rest, State).

process_bidi_stream_data(StreamId, Data, Fin, #h3_state{streams = Streams} = State) ->
    StreamState = maps:get(StreamId, Streams, #stream_state{}),
    Buffer = <<(StreamState#stream_state.buffer)/binary, Data/binary>>,
    {NewStreamState, State1} = process_h3_frames(StreamId, Buffer, Fin, StreamState, State),

    FinalStreamState = NewStreamState#stream_state{fin_received = Fin},
    %% Dispatch when headers are complete (not waiting for FIN)
    %% This enables stream-level concurrency for streaming uploads
    case FinalStreamState#stream_state.headers_received andalso
         not FinalStreamState#stream_state.dispatched of
        true ->
            %% Headers complete - dispatch to handler
            State2 = dispatch_request(StreamId, FinalStreamState, State1),
            %% Mark as dispatched
            DispatchedState = FinalStreamState#stream_state{dispatched = true},
            case Fin of
                true ->
                    %% Stream complete, clean up
                    State2#h3_state{streams = maps:remove(StreamId, State2#h3_state.streams)};
                false ->
                    %% Keep stream for body data
                    State2#h3_state{streams = maps:put(StreamId, DispatchedState, State2#h3_state.streams)}
            end;
        false when Fin ->
            %% Stream complete (already dispatched or headers-only), clean up
            State1#h3_state{streams = maps:remove(StreamId, State1#h3_state.streams)};
        false ->
            %% Waiting for more data
            State1#h3_state{streams = maps:put(StreamId, FinalStreamState, State1#h3_state.streams)}
    end.

process_h3_frames(StreamId, Buffer, Fin, StreamState, State) ->
    case livery_h3_frame:decode(Buffer) of
        {ok, Frame, Rest} ->
            {StreamState1, State1} = handle_h3_frame(StreamId, Frame, Fin andalso Rest =:= <<>>, StreamState, State),
            process_h3_frames(StreamId, Rest, Fin, StreamState1, State1);
        {more, _Needed} ->
            {StreamState#stream_state{buffer = Buffer}, State};
        {error, _Reason} ->
            {StreamState#stream_state{buffer = Buffer}, State}
    end.

handle_h3_frame(StreamId, {headers, Payload}, _Fin, StreamState,
                #h3_state{qpack_decoder = Decoder, max_field_section_size = MaxSize,
                          quic_conn = QuicConn} = State) ->
    %% Decode QPACK headers
    case livery_qpack:decode(Payload, Decoder) of
        {{ok, Headers}, Decoder1} ->
            %% Validate field section size per RFC 9114 Section 4.2.2
            %% Size = sum of (name length + value length + 32 overhead) per field
            FieldSectionSize = calculate_field_section_size(Headers),
            case FieldSectionSize > MaxSize of
                true ->
                    %% Field section too large - reset stream with H3_REQUEST_CANCELLED
                    %% Per RFC 9114, use H3_REQUEST_CANCELLED (0x010c) error code
                    quic:reset_stream(QuicConn, StreamId, 16#010c),
                    {StreamState, State#h3_state{qpack_decoder = Decoder1}};
                false ->
                    State1 = State#h3_state{qpack_decoder = Decoder1},
                    %% Check if this is initial headers or trailers
                    %% Trailers arrive AFTER data has been received
                    case StreamState#stream_state.data_received of
                        true ->
                            %% This is trailers (HEADERS after DATA)
                            %% Just store trailers - dispatch will happen in process_bidi_stream_data
                            %% when FIN is processed to avoid duplicate dispatches
                            StreamState1 = StreamState#stream_state{
                                trailers = Headers,
                                trailers_received = true
                            },
                            {StreamState1, State1};
                        false ->
                            %% This is initial headers
                            StreamState1 = StreamState#stream_state{
                                headers_received = true,
                                headers = Headers
                            },
                            %% Don't dispatch here - let process_bidi_stream_data handle it
                            %% when FIN is received to avoid duplicate dispatches
                            {StreamState1, State1}
                    end
            end;
        {{error, _Reason}, _Decoder1} ->
            {StreamState, State}
    end;

handle_h3_frame(StreamId, {data, Payload}, Fin,
                #stream_state{mode = websocket} = StreamState, State) ->
    %% WebSocket mode - DATA frames contain WebSocket frames
    process_websocket_data(StreamId, Payload, Fin, StreamState, State);

handle_h3_frame(_StreamId, {data, _Payload}, _Fin,
                #stream_state{headers_received = false} = StreamState, State) ->
    %% DATA before HEADERS - protocol error per RFC 9114
    %% Ignore the data and keep waiting for headers
    {StreamState, State};

handle_h3_frame(_StreamId, {data, Payload}, _Fin, StreamState, State) ->
    %% Normal mode - accumulate body using iolist prepend (O(1) instead of O(n))
    Body = StreamState#stream_state.body,
    StreamState1 = StreamState#stream_state{
        body = [Payload | Body],  %% Prepend for O(1), reverse at dispatch
        data_received = true
    },
    {StreamState1, State};

handle_h3_frame(_StreamId, _Frame, _Fin, StreamState, State) ->
    %% Unknown frame - ignore
    {StreamState, State}.

%%====================================================================
%% Internal - Request dispatch
%%====================================================================

dispatch_request(StreamId, #stream_state{headers = Headers, body = Body, trailers = Trailers} = StreamState,
                 #h3_state{handler = Handler, handler_opts = HandlerOpts, quic_conn = QuicConn} = State) ->
    %% Validate and extract pseudo-headers per RFC 9114 Section 4.3
    case validate_pseudo_headers(Headers) of
        {ok, Method, Scheme, Authority, Path, Protocol} ->
            %% Check for Extended CONNECT (RFC 9220)
            case {Method, Protocol} of
                {<<"CONNECT">>, <<"websocket">>} ->
                    %% Extended CONNECT with WebSocket protocol
                    handle_websocket_upgrade(StreamId, Headers, StreamState, Handler, HandlerOpts, State);
                _ ->
                    %% Normal request
                    dispatch_normal_request(StreamId, Method, Path, Scheme, Authority,
                                            Headers, Body, Trailers, Handler, HandlerOpts, State)
            end;
        {error, Reason} ->
            %% Invalid pseudo-headers - send 400 Bad Request
            ErrorMsg = case Reason of
                missing_method -> <<"Missing :method pseudo-header">>;
                missing_scheme -> <<"Missing :scheme pseudo-header">>;
                missing_path -> <<"Missing :path pseudo-header">>;
                missing_authority -> <<"Missing :authority pseudo-header">>;
                duplicate_pseudo_header -> <<"Duplicate pseudo-header">>;
                _ -> <<"Invalid request">>
            end,
            send_error_response(StreamId, 400, ErrorMsg, QuicConn, State)
    end.

%% @doc Validate pseudo-headers per RFC 9114 Section 4.3.
%% Required: :method, :scheme, :path (non-CONNECT)
%% :authority MUST be present for http/https
%% No duplicates allowed
-spec validate_pseudo_headers([{binary(), binary()}]) ->
    {ok, binary(), binary(), binary(), binary(), binary() | undefined} | {error, term()}.
validate_pseudo_headers(Headers) ->
    %% Extract pseudo-headers, checking for duplicates
    case extract_pseudo_headers(Headers) of
        {ok, PseudoMap} ->
            Method = maps:get(<<":method">>, PseudoMap, undefined),
            Scheme = maps:get(<<":scheme">>, PseudoMap, undefined),
            Authority = maps:get(<<":authority">>, PseudoMap, undefined),
            Path = maps:get(<<":path">>, PseudoMap, undefined),
            Protocol = maps:get(<<":protocol">>, PseudoMap, undefined),

            %% Validate required pseudo-headers
            case Method of
                undefined ->
                    {error, missing_method};
                <<"CONNECT">> when Protocol =/= undefined ->
                    %% Extended CONNECT (RFC 9220) - :scheme, :authority, :path required
                    case {Scheme, Authority, Path} of
                        {undefined, _, _} -> {error, missing_scheme};
                        {_, undefined, _} -> {error, missing_authority};
                        {_, _, undefined} -> {error, missing_path};
                        _ -> {ok, Method, Scheme, Authority, Path, Protocol}
                    end;
                <<"CONNECT">> ->
                    %% Regular CONNECT - only :authority required, no :scheme/:path
                    case Authority of
                        undefined -> {error, missing_authority};
                        _ -> {ok, Method, <<>>, Authority, <<>>, undefined}
                    end;
                _ ->
                    %% Normal request - :method, :scheme, :path, :authority required
                    case {Scheme, Path} of
                        {undefined, _} -> {error, missing_scheme};
                        {_, undefined} -> {error, missing_path};
                        _ ->
                            case Authority of
                                undefined -> {error, missing_authority};
                                <<>> -> {error, missing_authority};
                                _ -> {ok, Method, Scheme, Authority, Path, Protocol}
                            end
                    end
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc Extract pseudo-headers into a map, checking for duplicates.
extract_pseudo_headers(Headers) ->
    extract_pseudo_headers(Headers, #{}).

extract_pseudo_headers([], Acc) ->
    {ok, Acc};
extract_pseudo_headers([{<<$:, _/binary>> = Name, Value} | Rest], Acc) ->
    case maps:is_key(Name, Acc) of
        true ->
            %% Duplicate pseudo-header
            {error, duplicate_pseudo_header};
        false ->
            extract_pseudo_headers(Rest, Acc#{Name => Value})
    end;
extract_pseudo_headers([_ | Rest], Acc) ->
    %% Skip regular headers
    extract_pseudo_headers(Rest, Acc).

dispatch_normal_request(StreamId, Method, Path, _Scheme, _Authority,
                        Headers, Body, _Trailers, Handler, HandlerOpts,
                        #h3_state{peer = Peer} = State) ->
    %% Parse path and query string
    {PathOnly, Qs} = split_path_qs(Path),
    %% Convert body from iolist (reverse order) to binary
    BodyBin = iolist_to_binary(lists:reverse(Body)),
    %% Build request record
    Req = #livery_req{
        method = Method,
        path = PathOnly,
        qs = Qs,
        version = {3, 0},
        headers = filter_pseudo_headers(Headers),
        body = BodyBin,
        peer = Peer,
        sock = undefined,
        handler = Handler,
        handler_opts = HandlerOpts,
        has_body = BodyBin =/= <<>>,
        body_length = byte_size(BodyBin)
    },
    %% Call handler
    QuicConn = State#h3_state.quic_conn,
    try
        case Handler:init(Req, HandlerOpts) of
            {ok, Req1, HandlerState} ->
                case Handler:handle(Req1, HandlerState) of
                    {reply, Status, RespHeaders, RespBody, _HandlerState1} ->
                        %% Send response
                        AllHeaders = [{<<":status">>, integer_to_binary(Status)} | RespHeaders],
                        HasBody = RespBody =/= <<>> andalso RespBody =/= [],
                        Fin = not HasBody,
                        case do_send_headers(StreamId, AllHeaders, Fin, State) of
                            {ok, State1} when HasBody ->
                                do_send_data(StreamId, RespBody, true, State1);
                            _ ->
                                ok
                        end,
                        State;
                    {stream, Status, RespHeaders, StreamFun, _HandlerState1} ->
                        %% Send streaming response using spawn_monitor
                        spawn_monitor(fun() ->
                            send_h3_stream(StreamId, Status, RespHeaders, StreamFun, State)
                        end),
                        State;
                    _ ->
                        %% Unhandled handler return - send 500
                        send_error_response(StreamId, 500, <<"Internal Server Error">>, QuicConn, State)
                end;
            {error, _Reason} ->
                %% Handler init failed - send 500
                send_error_response(StreamId, 500, <<"Internal Server Error">>, QuicConn, State)
        end
    catch
        _:_ ->
            %% Handler exception - send 500
            send_error_response(StreamId, 500, <<"Internal Server Error">>, QuicConn, State)
    end.

get_header(Name, Headers, Default) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, Value} -> Value;
        false -> Default
    end.

filter_pseudo_headers(Headers) ->
    [{K, V} || {K, V} <- Headers, not is_pseudo_header(K)].

is_pseudo_header(<<$:, _/binary>>) -> true;
is_pseudo_header(_) -> false.

%% @doc Send an error response on a stream.
send_error_response(StreamId, Status, Body, QuicConn, State) ->
    Headers = [
        {<<":status">>, integer_to_binary(Status)},
        {<<"content-type">>, <<"text/plain">>},
        {<<"content-length">>, integer_to_binary(byte_size(Body))}
    ],
    case do_send_headers(StreamId, Headers, false, State) of
        {ok, State1} ->
            do_send_data(StreamId, Body, true, State1),
            State;
        {error, _Reason} ->
            %% Close stream on failure
            quic:reset_stream(QuicConn, StreamId, 16#010c),
            State
    end.

%% @doc Split path into path and query string.
split_path_qs(Path) ->
    case binary:split(Path, <<"?">>) of
        [PathOnly, Qs] -> {PathOnly, Qs};
        [PathOnly] -> {PathOnly, <<>>}
    end.

%% @doc Calculate field section size per RFC 9114 Section 4.2.2.
%% Size = sum of (name length + value length + 32 overhead) per field.
calculate_field_section_size(Headers) ->
    lists:foldl(fun({Name, Value}, Acc) ->
        Acc + byte_size(Name) + byte_size(Value) + 32
    end, 0, Headers).

%%====================================================================
%% Internal - Streaming response
%%====================================================================

%% @doc Send a streaming HTTP/3 response.
%% Sends headers, then calls StreamFun with a send callback, then finalizes.
send_h3_stream(StreamId, Status, RespHeaders, StreamFun, State) ->
    AllHeaders = [{<<":status">>, integer_to_binary(Status)} | RespHeaders],
    case do_send_headers(StreamId, AllHeaders, false, State) of
        {ok, State1} ->
            %% Create send function for the stream callback
            QuicConn = State1#h3_state.quic_conn,
            SendFun = fun
                (done) ->
                    %% Send empty DATA frame with FIN to close stream
                    quic:send_data(QuicConn, StreamId, <<>>, true);
                ({done, Trailers}) ->
                    %% Send trailers (HEADERS frame with FIN)
                    case do_send_headers(StreamId, Trailers, true, State1) of
                        {ok, _} -> ok;
                        {error, _} -> ok
                    end;
                (Chunk) ->
                    %% Send DATA frame with chunk
                    DataBin = iolist_to_binary(Chunk),
                    Frame = livery_h3_frame:encode_data(DataBin),
                    quic:send_data(QuicConn, StreamId, Frame, false)
            end,
            %% Call the stream function with our send callback
            try
                StreamFun(SendFun)
            catch
                Class:Reason:Stack ->
                    error_logger:error_msg("[H3] Stream function error on stream ~p: ~p:~p~n~p~n",
                                          [StreamId, Class, Reason, Stack]),
                    quic:send_data(QuicConn, StreamId, <<>>, true)
            end;
        {error, _Reason} ->
            ok
    end.

%%====================================================================
%% Internal - WebSocket over HTTP/3 (RFC 9220)
%%====================================================================

%% @doc Validate Extended CONNECT request for WebSocket.
%% RFC 9220 requires: :method=CONNECT, :protocol=websocket, :scheme, :authority, :path
-spec validate_connect_request([{binary(), binary()}]) -> ok | {error, term()}.
validate_connect_request(Headers) ->
    Method = get_header(<<":method">>, Headers, undefined),
    Protocol = get_header(<<":protocol">>, Headers, undefined),
    Scheme = get_header(<<":scheme">>, Headers, undefined),
    Authority = get_header(<<":authority">>, Headers, undefined),
    Path = get_header(<<":path">>, Headers, undefined),

    case {Method, Protocol, Scheme, Authority, Path} of
        {<<"CONNECT">>, <<"websocket">>, S, A, P}
          when S =/= undefined, A =/= undefined, P =/= undefined ->
            ok;
        _ ->
            {error, invalid_connect_request}
    end.

%% @doc Handle WebSocket upgrade via Extended CONNECT.
%% First check if peer advertised Extended CONNECT support in SETTINGS.
handle_websocket_upgrade(StreamId, _Headers, _StreamState, _Handler, _HandlerOpts,
                         #h3_state{peer_enable_connect_protocol = 0, quic_conn = QuicConn} = State) ->
    %% Peer didn't enable Extended CONNECT in SETTINGS - reject with 501
    send_error_response(StreamId, 501, <<"Extended CONNECT not supported">>, QuicConn, State);

handle_websocket_upgrade(StreamId, Headers, StreamState, Handler, HandlerOpts, State) ->
    case validate_connect_request(Headers) of
        ok ->
            Path = get_header(<<":path">>, Headers, <<"/">>),
            Scheme = get_header(<<":scheme">>, Headers, <<"https">>),
            Authority = get_header(<<":authority">>, Headers, <<>>),

            %% Build WebSocket request
            Req = #{
                method => <<"CONNECT">>,
                path => Path,
                scheme => Scheme,
                authority => Authority,
                headers => filter_pseudo_headers(Headers),
                body => <<>>,
                trailers => [],
                stream_id => StreamId,
                protocol => websocket
            },

            %% Call handler init to check if WebSocket is accepted
            try
                case Handler:init(Req, HandlerOpts) of
                    {websocket, Req1, HandlerState} ->
                        %% WebSocket accepted - send 200 and switch to websocket mode
                        accept_websocket(StreamId, Req1, HandlerState, StreamState, State);
                    {ok, _Req1, _HandlerState} ->
                        %% Handler didn't accept WebSocket, send 501
                        send_error_response(StreamId, 501, State);
                    {error, _Reason} ->
                        send_error_response(StreamId, 400, State)
                end
            catch
                _:_ ->
                    send_error_response(StreamId, 500, State)
            end;
        {error, _} ->
            send_error_response(StreamId, 400, State)
    end.

%% @doc Accept WebSocket connection - send 200 and switch stream to websocket mode.
accept_websocket(StreamId, Req, HandlerState, StreamState,
                 #h3_state{handler = Handler} = State) ->
    %% Send 200 response (no END_STREAM - stream stays open for WebSocket data)
    RespHeaders = [{<<":status">>, <<"200">>}],
    case do_send_headers(StreamId, RespHeaders, false, State) of
        {ok, State1} ->
            %% Update stream to websocket mode
            NewStreamState = StreamState#stream_state{
                mode = websocket,
                handler_state = {Handler, Req, HandlerState}
            },
            NewStreams = maps:put(StreamId, NewStreamState, State1#h3_state.streams),
            State1#h3_state{streams = NewStreams};
        {error, _Reason} ->
            State
    end.

%% @doc Send error response.
send_error_response(StreamId, Status, State) ->
    RespHeaders = [{<<":status">>, integer_to_binary(Status)}],
    case do_send_headers(StreamId, RespHeaders, true, State) of
        {ok, State1} -> State1;
        {error, _} -> State
    end.

%% @doc Process WebSocket data received in HTTP/3 DATA frames.
process_websocket_data(StreamId, Payload, Fin, StreamState, State) ->
    %% Accumulate data in WebSocket buffer
    Buffer = <<(StreamState#stream_state.ws_buffer)/binary, Payload/binary>>,

    %% Try to decode WebSocket frames from buffer
    {Frames, Rest} = decode_ws_frames(Buffer),

    %% Process decoded frames
    {StreamState1, State1} = process_ws_frames(StreamId, Frames, StreamState, State),

    %% Update buffer with remaining data
    StreamState2 = StreamState1#stream_state{ws_buffer = Rest},

    %% Handle connection close
    case Fin of
        true ->
            %% WebSocket closed by peer
            handle_ws_close(StreamId, StreamState2, State1);
        false ->
            {StreamState2, State1}
    end.

%% @doc Decode WebSocket frames from buffer.
%% Returns {Frames, RemainingBuffer}.
-spec decode_ws_frames(binary()) -> {[livery_ws:frame()], binary()}.
decode_ws_frames(Buffer) ->
    decode_ws_frames(Buffer, []).

decode_ws_frames(Buffer, Acc) ->
    case livery_ws:decode_frame(Buffer) of
        {ok, Opcode, Payload, _Fin, Rest} ->
            decode_ws_frames(Rest, [{Opcode, Payload} | Acc]);
        {more, _} ->
            {lists:reverse(Acc), Buffer};
        {error, _} ->
            %% Clear buffer on decode error to avoid repeated failures
            {lists:reverse(Acc), <<>>}
    end.

%% @doc Process decoded WebSocket frames by calling handler.
process_ws_frames(_StreamId, [], StreamState, State) ->
    {StreamState, State};
process_ws_frames(StreamId, [Frame | Rest], StreamState, State) ->
    {StreamState1, State1} = process_single_ws_frame(StreamId, Frame, StreamState, State),
    process_ws_frames(StreamId, Rest, StreamState1, State1).

process_single_ws_frame(StreamId, {ping, Payload}, StreamState, State) ->
    %% Auto-respond to ping with pong
    PongFrame = livery_ws:encode_pong(Payload),
    DataFrame = livery_h3_frame:encode_data(PongFrame),
    quic:send_data(State#h3_state.quic_conn, StreamId, DataFrame, false),
    {StreamState, State};

process_single_ws_frame(_StreamId, {pong, _Payload}, StreamState, State) ->
    %% Pong received - ignore
    {StreamState, State};

process_single_ws_frame(StreamId, {close, Payload}, StreamState, State) ->
    %% Close frame - respond with close and mark stream as closing
    {Code, _Reason} = parse_close_payload(Payload),
    CloseFrame = livery_ws:encode_close(Code),
    DataFrame = livery_h3_frame:encode_data(CloseFrame),
    quic:send_data(State#h3_state.quic_conn, StreamId, DataFrame, true),
    {StreamState, State};

process_single_ws_frame(StreamId, Frame, StreamState,
                        #h3_state{handler = Handler} = State) ->
    %% Call handler's websocket_handle callback
    case StreamState#stream_state.handler_state of
        {_HandlerMod, Req, HandlerState} ->
            case call_websocket_handle(Handler, Frame, Req, HandlerState) of
                {ok, NewHandlerState} ->
                    NewStreamState = StreamState#stream_state{
                        handler_state = {Handler, Req, NewHandlerState}
                    },
                    {NewStreamState, State};
                {reply, ReplyFrame, NewHandlerState} ->
                    %% Send reply frame
                    send_ws_frame_internal(StreamId, ReplyFrame, State),
                    NewStreamState = StreamState#stream_state{
                        handler_state = {Handler, Req, NewHandlerState}
                    },
                    {NewStreamState, State};
                {stop, _Reason, _NewHandlerState} ->
                    %% Close WebSocket
                    CloseFrame = livery_ws:encode_close(1000),
                    DataFrame = livery_h3_frame:encode_data(CloseFrame),
                    quic:send_data(State#h3_state.quic_conn, StreamId, DataFrame, true),
                    {StreamState, State}
            end;
        _ ->
            {StreamState, State}
    end.

%% @doc Call handler's websocket_handle callback if it exists.
call_websocket_handle(Handler, Frame, _Req, HandlerState) ->
    case erlang:function_exported(Handler, websocket_handle, 2) of
        true ->
            Handler:websocket_handle(Frame, HandlerState);
        false ->
            %% No websocket_handle callback, just keep state
            {ok, HandlerState}
    end.

%% @doc Handle WebSocket close.
handle_ws_close(_StreamId, StreamState, State) ->
    %% Stream is closing, return updated state
    {StreamState, State}.

%% @doc Parse close frame payload.
parse_close_payload(<<Code:16, Reason/binary>>) ->
    {Code, Reason};
parse_close_payload(<<>>) ->
    {1000, <<>>};
parse_close_payload(_) ->
    {1000, <<>>}.

%% @doc Send WebSocket frame to client (internal).
send_ws_frame_internal(StreamId, Frame, #h3_state{quic_conn = QuicConn}) ->
    WsFrame = encode_ws_frame(Frame),
    DataFrame = livery_h3_frame:encode_data(WsFrame),
    quic:send_data(QuicConn, StreamId, DataFrame, false).

%% @doc Encode a WebSocket frame for sending.
encode_ws_frame({text, Text}) ->
    livery_ws:encode_text(Text);
encode_ws_frame({binary, Data}) ->
    livery_ws:encode_binary(Data);
encode_ws_frame({ping, Payload}) ->
    livery_ws:encode_ping(Payload);
encode_ws_frame({pong, Payload}) ->
    livery_ws:encode_pong(Payload);
encode_ws_frame({close, Code}) when is_integer(Code) ->
    livery_ws:encode_close(Code);
encode_ws_frame({close, Code, Reason}) ->
    livery_ws:encode_close(Code, Reason);
encode_ws_frame(Frame) when is_binary(Frame) ->
    Frame.
