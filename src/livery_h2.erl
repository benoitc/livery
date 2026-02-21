%% @doc HTTP/2 protocol handler.
%%
%% Manages HTTP/2 connection state including:
%% - Connection preface handling
%% - SETTINGS exchange
%% - Stream multiplexing
%% - Flow control
%% - HPACK compression contexts
-module(livery_h2).

-export([
    init/1,
    handle_data/2,
    send_response/5,
    send_stream_data/4,
    send_stream_end/2,
    close/2
]).

-include("livery.hrl").

%% Request record for H2
-record(h2_request, {
    method :: binary(),
    path :: binary(),
    qs :: binary(),
    scheme :: binary(),
    authority :: binary(),
    headers :: [{binary(), binary()}],
    body :: binary() | undefined
}).

%% Connection preface
-define(CONNECTION_PREFACE, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>).
-define(PREFACE_SIZE, 24).

%% Default values
-define(DEFAULT_WINDOW_SIZE, 65535).
-define(DEFAULT_MAX_FRAME_SIZE, 16384).
-define(DEFAULT_HEADER_TABLE_SIZE, 4096).
-define(DEFAULT_MAX_CONCURRENT_STREAMS, 100).

%% Stream states
-type stream_state() :: idle | open | half_closed_remote | half_closed_local | closed.

-record(stream, {
    id :: non_neg_integer(),
    state = idle :: stream_state(),
    window_size :: integer(),
    request :: undefined | #h2_request{},
    header_block = <<>> :: binary(),  %% For CONTINUATION
    end_headers = false :: boolean()
}).

-record(h2_state, {
    %% Connection state
    phase = preface :: preface | settings | open,
    buffer = <<>> :: binary(),

    %% Settings (local = what we send, remote = what peer sends)
    local_settings :: map(),
    remote_settings :: map(),
    settings_acked = false :: boolean(),

    %% Flow control
    conn_window_out :: integer(),  %% Outbound (to peer)
    conn_window_in :: integer(),   %% Inbound (from peer)

    %% Streams
    streams = #{} :: #{non_neg_integer() => #stream{}},
    last_stream_id = 0 :: non_neg_integer(),
    max_stream_id = 0 :: non_neg_integer(),

    %% HPACK
    encoder :: livery_hpack:encoder(),
    decoder :: livery_hpack:decoder(),

    %% Handler
    handler :: module(),
    handler_opts :: term()
}).

-opaque state() :: #h2_state{}.
-export_type([state/0]).

%% @doc Initialize HTTP/2 state.
-spec init(map()) -> state().
init(Opts) ->
    Handler = maps:get(handler, Opts),
    HandlerOpts = maps:get(handler_opts, Opts, #{}),
    LocalSettings = maps:merge(livery_h2_frame:default_settings(),
                               maps:get(settings, Opts, #{})),
    #h2_state{
        local_settings = LocalSettings,
        remote_settings = livery_h2_frame:default_settings(),
        conn_window_out = ?DEFAULT_WINDOW_SIZE,
        conn_window_in = ?DEFAULT_WINDOW_SIZE,
        encoder = livery_hpack:encoder_new(maps:get(header_table_size, LocalSettings)),
        decoder = livery_hpack:decoder_new(maps:get(header_table_size, LocalSettings)),
        handler = Handler,
        handler_opts = HandlerOpts
    }.

%% @doc Handle incoming data.
-spec handle_data(binary(), state()) ->
    {ok, [Response], state()} |
    {error, term(), state()}
    when Response :: {send, iodata()} | {request, non_neg_integer(), tuple()}.
handle_data(Data, #h2_state{buffer = Buffer} = State) ->
    NewBuffer = <<Buffer/binary, Data/binary>>,
    handle_buffer(State#h2_state{buffer = NewBuffer}, []).

handle_buffer(#h2_state{phase = preface, buffer = Buffer} = State, Acc) ->
    case byte_size(Buffer) >= ?PREFACE_SIZE of
        true ->
            <<Preface:?PREFACE_SIZE/binary, Rest/binary>> = Buffer,
            case Preface =:= ?CONNECTION_PREFACE of
                true ->
                    %% Send our SETTINGS
                    SettingsFrame = livery_h2_frame:encode_settings(State#h2_state.local_settings),
                    handle_buffer(
                        State#h2_state{phase = settings, buffer = Rest},
                        [{send, SettingsFrame} | Acc]
                    );
                false ->
                    {error, {protocol_error, invalid_preface}, State}
            end;
        false ->
            {ok, lists:reverse(Acc), State}
    end;

handle_buffer(#h2_state{buffer = Buffer} = State, Acc) ->
    case livery_h2_frame:decode(Buffer) of
        {ok, Frame, Rest} ->
            case handle_frame(Frame, State#h2_state{buffer = Rest}) of
                {ok, Responses, NewState} ->
                    handle_buffer(NewState, Responses ++ Acc);
                {error, Reason, NewState} ->
                    {error, Reason, NewState}
            end;
        {more, _} ->
            {ok, lists:reverse(Acc), State};
        {error, Reason} ->
            {error, Reason, State}
    end.

%% Frame handlers
handle_frame({settings, Settings}, #h2_state{phase = settings} = State) ->
    %% First SETTINGS from peer
    NewState = apply_settings(Settings, State),
    Ack = livery_h2_frame:encode_settings_ack(),
    {ok, [{send, Ack}], NewState#h2_state{phase = open}};

handle_frame({settings, Settings}, #h2_state{phase = open} = State) ->
    NewState = apply_settings(Settings, State),
    Ack = livery_h2_frame:encode_settings_ack(),
    {ok, [{send, Ack}], NewState};

handle_frame({settings_ack}, State) ->
    {ok, [], State#h2_state{settings_acked = true}};

handle_frame({ping, OpaqueData}, State) ->
    Ack = livery_h2_frame:encode_ping_ack(OpaqueData),
    {ok, [{send, Ack}], State};

handle_frame({ping_ack, _OpaqueData}, State) ->
    {ok, [], State};

handle_frame({goaway, LastStreamId, ErrorCode, _DebugData}, State) ->
    %% Peer is closing connection
    {error, {goaway, LastStreamId, ErrorCode}, State};

handle_frame({window_update, 0, Increment}, #h2_state{conn_window_out = Window} = State) ->
    %% Connection-level window update
    NewWindow = Window + Increment,
    if
        NewWindow > 2147483647 ->
            {error, flow_control_error, State};
        true ->
            {ok, [], State#h2_state{conn_window_out = NewWindow}}
    end;

handle_frame({window_update, StreamId, Increment}, State) ->
    %% Stream-level window update
    case get_stream(StreamId, State) of
        {ok, Stream} ->
            NewWindow = Stream#stream.window_size + Increment,
            if
                NewWindow > 2147483647 ->
                    RstFrame = livery_h2_frame:encode_rst_stream(StreamId, 3), %% FLOW_CONTROL_ERROR
                    {ok, [{send, RstFrame}], remove_stream(StreamId, State)};
                true ->
                    NewStream = Stream#stream{window_size = NewWindow},
                    {ok, [], update_stream(NewStream, State)}
            end;
        error ->
            %% Ignore window update for unknown stream
            {ok, [], State}
    end;

handle_frame({headers, StreamId, HeaderBlock, EndStream, EndHeaders}, State) ->
    handle_headers(StreamId, HeaderBlock, EndStream, EndHeaders, undefined, State);

handle_frame({headers, StreamId, HeaderBlock, EndStream, EndHeaders, Priority}, State) ->
    handle_headers(StreamId, HeaderBlock, EndStream, EndHeaders, Priority, State);

handle_frame({continuation, StreamId, HeaderBlock, EndHeaders}, State) ->
    case get_stream(StreamId, State) of
        {ok, #stream{end_headers = false, header_block = Existing} = Stream} ->
            NewBlock = <<Existing/binary, HeaderBlock/binary>>,
            case EndHeaders of
                true ->
                    %% Complete the headers
                    finalize_headers(Stream#stream{header_block = NewBlock}, State);
                false ->
                    NewStream = Stream#stream{header_block = NewBlock},
                    {ok, [], update_stream(NewStream, State)}
            end;
        _ ->
            {error, protocol_error, State}
    end;

handle_frame({data, StreamId, Data, EndStream}, State) ->
    case get_stream(StreamId, State) of
        {ok, #stream{state = open, request = Req} = Stream} ->
            %% Update connection window
            DataSize = byte_size(Data),
            NewConnWindow = State#h2_state.conn_window_in - DataSize,
            NewStreamWindow = Stream#stream.window_size - DataSize,

            %% Accumulate body
            ExistingBody = case Req#h2_request.body of
                undefined -> <<>>;
                B -> B
            end,
            NewBody = <<ExistingBody/binary, Data/binary>>,
            NewReq = Req#h2_request{body = NewBody},
            NewStream = Stream#stream{
                window_size = NewStreamWindow,
                request = NewReq
            },

            State1 = State#h2_state{conn_window_in = NewConnWindow},
            State2 = update_stream(NewStream, State1),

            %% Send window updates if needed
            Responses = maybe_send_window_updates(StreamId, DataSize, State2),

            case EndStream of
                true ->
                    %% Request complete
                    FinalStream = NewStream#stream{state = half_closed_remote},
                    State3 = update_stream(FinalStream, State2),
                    {ok, [{request, StreamId, NewReq} | Responses], State3};
                false ->
                    {ok, Responses, State2}
            end;
        {ok, #stream{state = half_closed_remote}} ->
            RstFrame = livery_h2_frame:encode_rst_stream(StreamId, 5), %% STREAM_CLOSED
            {ok, [{send, RstFrame}], State};
        _ ->
            {error, protocol_error, State}
    end;

handle_frame({rst_stream, StreamId, _ErrorCode}, State) ->
    {ok, [], remove_stream(StreamId, State)};

handle_frame({push_promise, _, _, _, _}, State) ->
    %% Servers don't receive PUSH_PROMISE
    {error, protocol_error, State};

handle_frame(_Frame, State) ->
    %% Unknown frame types are ignored
    {ok, [], State}.

%% Handle HEADERS frame
handle_headers(StreamId, HeaderBlock, EndStream, EndHeaders, _Priority, State) ->
    %% Validate stream ID - client streams must be odd and increasing
    IsValid = case StreamId =< State#h2_state.max_stream_id of
        true when StreamId rem 2 =:= 1 ->
            %% Reused stream ID from client
            false;
        _ ->
            true
    end,

    case IsValid of
        false ->
            {error, protocol_error, State};
        true ->
            %% Create new stream
            InitialWindow = maps:get(initial_window_size, State#h2_state.remote_settings),
            Stream = #stream{
                id = StreamId,
                state = case EndStream of true -> half_closed_remote; false -> open end,
                window_size = InitialWindow,
                header_block = HeaderBlock,
                end_headers = EndHeaders
            },

            NewState = State#h2_state{max_stream_id = max(StreamId, State#h2_state.max_stream_id)},
            State1 = update_stream(Stream, NewState),

            case EndHeaders of
                true ->
                    finalize_headers(Stream, State1);
                false ->
                    {ok, [], State1}
            end
    end.

finalize_headers(#stream{id = StreamId, header_block = HeaderBlock, state = StreamState} = Stream, State) ->
    case livery_hpack:decode(HeaderBlock, State#h2_state.decoder) of
        {ok, Headers, Decoder1} ->
            %% Build request
            Method = proplists:get_value(<<":method">>, Headers, <<"GET">>),
            Path = proplists:get_value(<<":path">>, Headers, <<"/">>),
            Scheme = proplists:get_value(<<":scheme">>, Headers, <<"https">>),
            Authority = proplists:get_value(<<":authority">>, Headers, <<>>),

            %% Split path and query string
            {PathOnly, Qs} = case binary:split(Path, <<"?">>) of
                [P] -> {P, <<>>};
                [P, Q] -> {P, Q}
            end,

            %% Filter out pseudo-headers
            RegularHeaders = [{N, V} || {N, V} <- Headers, binary:first(N) =/= $:],

            Request = #h2_request{
                method = Method,
                path = PathOnly,
                qs = Qs,
                scheme = Scheme,
                authority = Authority,
                headers = RegularHeaders,
                body = undefined
            },

            NewStream = Stream#stream{
                request = Request,
                header_block = <<>>,
                end_headers = true
            },
            State1 = State#h2_state{decoder = Decoder1},
            State2 = update_stream(NewStream, State1),

            %% If request is complete (no body), dispatch immediately
            case StreamState of
                half_closed_remote ->
                    {ok, [{request, StreamId, Request}], State2};
                open ->
                    {ok, [], State2}
            end;
        {error, Reason} ->
            {error, {compression_error, Reason}, State}
    end.

%% Apply peer's settings
apply_settings(Settings, State) ->
    NewRemote = maps:merge(State#h2_state.remote_settings, Settings),

    %% Update HPACK encoder if header table size changed
    Encoder = case maps:get(header_table_size, Settings, undefined) of
        undefined -> State#h2_state.encoder;
        Size -> livery_hpack:encoder_set_max_size(Size, State#h2_state.encoder)
    end,

    %% Update stream initial window sizes if changed
    State1 = case maps:get(initial_window_size, Settings, undefined) of
        undefined -> State;
        NewSize ->
            OldSize = maps:get(initial_window_size, State#h2_state.remote_settings),
            Delta = NewSize - OldSize,
            update_all_stream_windows(Delta, State)
    end,

    State1#h2_state{
        remote_settings = NewRemote,
        encoder = Encoder
    }.

update_all_stream_windows(Delta, #h2_state{streams = Streams} = State) ->
    NewStreams = maps:map(fun(_Id, Stream) ->
        Stream#stream{window_size = Stream#stream.window_size + Delta}
    end, Streams),
    State#h2_state{streams = NewStreams}.

%% Stream management
get_stream(StreamId, #h2_state{streams = Streams}) ->
    case maps:find(StreamId, Streams) of
        {ok, Stream} -> {ok, Stream};
        error -> error
    end.

update_stream(#stream{id = StreamId} = Stream, #h2_state{streams = Streams} = State) ->
    State#h2_state{streams = Streams#{StreamId => Stream}}.

remove_stream(StreamId, #h2_state{streams = Streams} = State) ->
    State#h2_state{streams = maps:remove(StreamId, Streams)}.

%% Flow control
maybe_send_window_updates(_StreamId, DataSize, _State) when DataSize < 16384 ->
    [];
maybe_send_window_updates(StreamId, DataSize, _State) ->
    %% Send window updates for both connection and stream
    ConnUpdate = livery_h2_frame:encode_window_update(0, DataSize),
    StreamUpdate = livery_h2_frame:encode_window_update(StreamId, DataSize),
    [{send, ConnUpdate}, {send, StreamUpdate}].

%% @doc Send a response on a stream.
-spec send_response(non_neg_integer(), non_neg_integer(), [{binary(), binary()}], binary(), state()) ->
    {ok, iodata(), state()}.
send_response(StreamId, Status, Headers, Body, State) ->
    %% Add :status pseudo-header
    StatusBin = integer_to_binary(Status),
    AllHeaders = [{<<":status">>, StatusBin} | Headers],

    %% Encode headers with HPACK
    {HeaderBlock, Encoder1} = livery_hpack:encode(AllHeaders, State#h2_state.encoder),
    HeaderBlockBin = iolist_to_binary(HeaderBlock),

    EndStream = byte_size(Body) =:= 0,
    HeadersFrame = livery_h2_frame:encode_headers(StreamId, HeaderBlockBin, EndStream, true),

    Frames = case EndStream of
        true ->
            [HeadersFrame];
        false ->
            DataFrame = livery_h2_frame:encode_data(StreamId, Body, true),
            [HeadersFrame, DataFrame]
    end,

    %% Update stream state
    NewState = case get_stream(StreamId, State) of
        {ok, Stream} ->
            update_stream(Stream#stream{state = closed}, State#h2_state{encoder = Encoder1});
        error ->
            State#h2_state{encoder = Encoder1}
    end,

    {ok, Frames, NewState}.

%% @doc Send data on a stream (for streaming responses).
-spec send_stream_data(non_neg_integer(), binary(), boolean(), state()) ->
    {ok, iodata(), state()}.
send_stream_data(StreamId, Data, EndStream, State) ->
    DataFrame = livery_h2_frame:encode_data(StreamId, Data, EndStream),

    NewState = case EndStream of
        true -> remove_stream(StreamId, State);
        false -> State
    end,

    {ok, [DataFrame], NewState}.

%% @doc Send stream end (empty DATA frame with END_STREAM).
-spec send_stream_end(non_neg_integer(), state()) -> {ok, iodata(), state()}.
send_stream_end(StreamId, State) ->
    DataFrame = livery_h2_frame:encode_data(StreamId, <<>>, true),
    {ok, [DataFrame], remove_stream(StreamId, State)}.

%% @doc Close the connection with GOAWAY.
-spec close(non_neg_integer(), state()) -> iodata().
close(ErrorCode, #h2_state{max_stream_id = LastStreamId}) ->
    livery_h2_frame:encode_goaway(LastStreamId, ErrorCode, <<>>).
