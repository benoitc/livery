%% @doc HTTP/3 connection handler for livery server.
%%
%% Handles HTTP/3 connections over QUIC, including:
%% - Control stream setup
%% - QPACK encoder/decoder streams
%% - Request stream multiplexing
%% - HEADERS and DATA frame processing
-module(livery_h3).

-behaviour(gen_statem).

-export([
    %% API
    start_link/3,
    send_response/5,
    send_headers/4,
    send_data/4,
    send_trailers/3,
    close/2,
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

%% Default max field section size per RFC 9114 (no default, use 16KB as sensible limit)
-define(DEFAULT_MAX_FIELD_SECTION_SIZE, 16384).

-record(h3_state, {
    quic_conn :: reference() | undefined,
    handler :: module(),
    handler_opts :: term(),
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
    %% QPACK state
    qpack_encoder :: livery_qpack:state(),
    qpack_decoder :: livery_qpack:state()
}).

-record(stream_state, {
    buffer = <<>> :: binary(),
    headers = [] :: [{binary(), binary()}],
    headers_received = false :: boolean(),
    body = <<>> :: binary(),
    data_received = false :: boolean(),
    trailers = [] :: [{binary(), binary()}],
    trailers_received = false :: boolean(),
    fin_received = false :: boolean(),
    handler_state :: term()
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
    %% Set up HTTP/3 control streams
    State1 = setup_h3_streams(State),
    {ok, connected, State1}.

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

handle_event(info, _Msg, _StateName, State) ->
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
    State1#h3_state{
        uni_streams = maps:put(StreamId, NewInfo, UniStreams),
        settings_received = true
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
    State1 = State#h3_state{peer_max_field_section_size = MaxFieldSize},
    apply_peer_settings(Rest, State1);
apply_peer_settings([_ | Rest], State) ->
    %% Skip non-settings frames (GOAWAY, etc.)
    apply_peer_settings(Rest, State).

process_bidi_stream_data(StreamId, Data, Fin, #h3_state{streams = Streams} = State) ->
    StreamState = maps:get(StreamId, Streams, #stream_state{}),
    Buffer = <<(StreamState#stream_state.buffer)/binary, Data/binary>>,
    {NewStreamState, State1} = process_h3_frames(StreamId, Buffer, Fin, StreamState, State),

    FinalStreamState = NewStreamState#stream_state{fin_received = Fin},
    NewStreams = case Fin andalso FinalStreamState#stream_state.headers_received of
        true ->
            %% Stream complete - dispatch to handler
            State2 = dispatch_request(StreamId, FinalStreamState, State1),
            maps:remove(StreamId, State2#h3_state.streams);
        false ->
            maps:put(StreamId, FinalStreamState, State1#h3_state.streams)
    end,
    State1#h3_state{streams = NewStreams}.

process_h3_frames(StreamId, Buffer, Fin, StreamState, State) ->
    case livery_h3_frame:decode(Buffer) of
        {ok, Frame, Rest} ->
            {StreamState1, State1} = handle_h3_frame(StreamId, Frame, Fin andalso Rest =:= <<>>, StreamState, State),
            process_h3_frames(StreamId, Rest, Fin, StreamState1, State1);
        {more, _} ->
            {StreamState#stream_state{buffer = Buffer}, State};
        {error, _} ->
            {StreamState#stream_state{buffer = Buffer}, State}
    end.

handle_h3_frame(StreamId, {headers, Payload}, Fin, StreamState,
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
                            StreamState1 = StreamState#stream_state{
                                trailers = Headers,
                                trailers_received = true
                            },
                            %% Trailers must have FIN set per RFC 9114
                            case Fin of
                                true ->
                                    {StreamState1, dispatch_request(StreamId, StreamState1, State1)};
                                false ->
                                    %% Invalid: trailers without FIN - store anyway
                                    {StreamState1, State1}
                            end;
                        false ->
                            %% This is initial headers
                            StreamState1 = StreamState#stream_state{
                                headers_received = true,
                                headers = Headers
                            },
                            %% If Fin is true and we have headers, request is complete (no body)
                            case Fin of
                                true ->
                                    {StreamState1, dispatch_request(StreamId, StreamState1, State1)};
                                false ->
                                    {StreamState1, State1}
                            end
                    end
            end;
        {{error, _Reason}, _Decoder1} ->
            {StreamState, State}
    end;

handle_h3_frame(_StreamId, {data, Payload}, _Fin, StreamState, State) ->
    Body = StreamState#stream_state.body,
    StreamState1 = StreamState#stream_state{
        body = <<Body/binary, Payload/binary>>,
        data_received = true
    },
    {StreamState1, State};

handle_h3_frame(_StreamId, _Frame, _Fin, StreamState, State) ->
    %% Unknown frame - ignore
    {StreamState, State}.

%%====================================================================
%% Internal - Request dispatch
%%====================================================================

dispatch_request(StreamId, #stream_state{headers = Headers, body = Body, trailers = Trailers},
                 #h3_state{handler = Handler, handler_opts = HandlerOpts} = State) ->
    %% Extract pseudo-headers
    Method = get_header(<<":method">>, Headers, <<"GET">>),
    Path = get_header(<<":path">>, Headers, <<"/">>),
    Scheme = get_header(<<":scheme">>, Headers, <<"https">>),
    Authority = get_header(<<":authority">>, Headers, <<>>),

    %% Build request record
    Req = #{
        method => Method,
        path => Path,
        scheme => Scheme,
        authority => Authority,
        headers => filter_pseudo_headers(Headers),
        body => Body,
        trailers => Trailers,
        stream_id => StreamId,
        protocol => h3
    },

    %% Call handler
    try
        case Handler:init(Req, HandlerOpts) of
            {ok, Req1, HandlerState} ->
                case Handler:handle(Req1, HandlerState) of
                    {reply, Status, RespHeaders, RespBody, _HandlerState1} ->
                        %% Send response
                        spawn_link(fun() ->
                            AllHeaders = [{<<":status">>, integer_to_binary(Status)} | RespHeaders],
                            HasBody = RespBody =/= <<>> andalso RespBody =/= [],
                            Fin = not HasBody,
                            case do_send_headers(StreamId, AllHeaders, Fin, State) of
                                {ok, State1} when HasBody ->
                                    do_send_data(StreamId, RespBody, true, State1);
                                _ ->
                                    ok
                            end
                        end),
                        State;
                    _ ->
                        State
                end;
            {error, _Reason} ->
                State
        end
    catch
        _:_ ->
            %% Send 500 error
            State
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

%% @doc Calculate field section size per RFC 9114 Section 4.2.2.
%% Size = sum of (name length + value length + 32 overhead) per field.
calculate_field_section_size(Headers) ->
    lists:foldl(fun({Name, Value}, Acc) ->
        Acc + byte_size(Name) + byte_size(Value) + 32
    end, 0, Headers).
