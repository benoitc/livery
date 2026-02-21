%% @doc HTTP/2 frame encoding and decoding (RFC 7540).
%%
%% Frame format:
%% +-----------------------------------------------+
%% |                 Length (24)                   |
%% +---------------+---------------+---------------+
%% |   Type (8)    |   Flags (8)   |
%% +-+-------------+---------------+-------------------------------+
%% |R|                 Stream Identifier (31)                      |
%% +=+=============================================================+
%% |                   Frame Payload (0...)                      ...
%% +---------------------------------------------------------------+
-module(livery_h2_frame).

-export([
    %% Encoding
    encode/1,
    encode_data/3,
    encode_headers/3,
    encode_headers/4,
    encode_priority/4,
    encode_rst_stream/2,
    encode_settings/1,
    encode_settings_ack/0,
    encode_push_promise/4,
    encode_ping/1,
    encode_ping_ack/1,
    encode_goaway/3,
    encode_window_update/2,
    encode_continuation/3,
    %% Decoding
    decode/1,
    decode_settings_payload/1,
    %% Constants
    frame_header_size/0,
    default_settings/0
]).

%% Frame types
-define(FRAME_DATA, 16#0).
-define(FRAME_HEADERS, 16#1).
-define(FRAME_PRIORITY, 16#2).
-define(FRAME_RST_STREAM, 16#3).
-define(FRAME_SETTINGS, 16#4).
-define(FRAME_PUSH_PROMISE, 16#5).
-define(FRAME_PING, 16#6).
-define(FRAME_GOAWAY, 16#7).
-define(FRAME_WINDOW_UPDATE, 16#8).
-define(FRAME_CONTINUATION, 16#9).

%% Flags
-define(FLAG_END_STREAM, 16#1).
-define(FLAG_END_HEADERS, 16#4).
-define(FLAG_PADDED, 16#8).
-define(FLAG_PRIORITY, 16#20).
-define(FLAG_ACK, 16#1).

%% Settings identifiers
-define(SETTINGS_HEADER_TABLE_SIZE, 16#1).
-define(SETTINGS_ENABLE_PUSH, 16#2).
-define(SETTINGS_MAX_CONCURRENT_STREAMS, 16#3).
-define(SETTINGS_INITIAL_WINDOW_SIZE, 16#4).
-define(SETTINGS_MAX_FRAME_SIZE, 16#5).
-define(SETTINGS_MAX_HEADER_LIST_SIZE, 16#6).

%% Error codes
-define(NO_ERROR, 16#0).
-define(PROTOCOL_ERROR, 16#1).
-define(INTERNAL_ERROR, 16#2).
-define(FLOW_CONTROL_ERROR, 16#3).
-define(SETTINGS_TIMEOUT, 16#4).
-define(STREAM_CLOSED, 16#5).
-define(FRAME_SIZE_ERROR, 16#6).
-define(REFUSED_STREAM, 16#7).
-define(CANCEL, 16#8).
-define(COMPRESSION_ERROR, 16#9).
-define(CONNECT_ERROR, 16#a).
-define(ENHANCE_YOUR_CALM, 16#b).
-define(INADEQUATE_SECURITY, 16#c).
-define(HTTP_1_1_REQUIRED, 16#d).

%% Types
-type frame_type() :: data | headers | priority | rst_stream | settings |
                      push_promise | ping | goaway | window_update | continuation.
-type stream_id() :: non_neg_integer().
-type error_code() :: non_neg_integer().
-type settings() :: #{atom() => non_neg_integer()}.

-type frame() ::
    {data, stream_id(), binary(), boolean()} |
    {headers, stream_id(), binary(), boolean(), boolean()} |
    {headers, stream_id(), binary(), boolean(), boolean(), priority()} |
    {priority, stream_id(), priority()} |
    {rst_stream, stream_id(), error_code()} |
    {settings, settings()} |
    {settings_ack} |
    {push_promise, stream_id(), stream_id(), binary()} |
    {ping, binary()} |
    {ping_ack, binary()} |
    {goaway, stream_id(), error_code(), binary()} |
    {window_update, stream_id(), non_neg_integer()} |
    {continuation, stream_id(), binary(), boolean()}.

-type priority() :: {Exclusive :: boolean(), StreamDep :: stream_id(), Weight :: 1..256}.

-type decode_result() ::
    {ok, frame(), Rest :: binary()} |
    {more, non_neg_integer()} |
    {error, term()}.

-export_type([frame/0, frame_type/0, stream_id/0, error_code/0, settings/0, priority/0]).

%% @doc Frame header size in bytes.
-spec frame_header_size() -> 9.
frame_header_size() -> 9.

%% @doc Default HTTP/2 settings.
-spec default_settings() -> settings().
default_settings() ->
    #{
        header_table_size => 4096,
        enable_push => 1,
        max_concurrent_streams => 100,
        initial_window_size => 65535,
        max_frame_size => 16384,
        max_header_list_size => 8192
    }.

%% ===================================================================
%% Encoding
%% ===================================================================

%% @doc Encode a frame to binary.
-spec encode(frame()) -> iodata().
encode({data, StreamId, Data, EndStream}) ->
    encode_data(StreamId, Data, EndStream);
encode({headers, StreamId, HeaderBlock, EndStream, EndHeaders}) ->
    encode_headers(StreamId, HeaderBlock, EndStream, EndHeaders);
encode({headers, StreamId, HeaderBlock, EndStream, EndHeaders, Priority}) ->
    encode_headers_with_priority(StreamId, HeaderBlock, EndStream, EndHeaders, Priority);
encode({priority, StreamId, Priority}) ->
    {Exclusive, StreamDep, Weight} = Priority,
    encode_priority(StreamId, Exclusive, StreamDep, Weight);
encode({rst_stream, StreamId, ErrorCode}) ->
    encode_rst_stream(StreamId, ErrorCode);
encode({settings, Settings}) ->
    encode_settings(Settings);
encode({settings_ack}) ->
    encode_settings_ack();
encode({push_promise, StreamId, PromisedStreamId, HeaderBlock}) ->
    encode_push_promise(StreamId, PromisedStreamId, HeaderBlock, true);
encode({ping, OpaqueData}) ->
    encode_ping(OpaqueData);
encode({ping_ack, OpaqueData}) ->
    encode_ping_ack(OpaqueData);
encode({goaway, LastStreamId, ErrorCode, DebugData}) ->
    encode_goaway(LastStreamId, ErrorCode, DebugData);
encode({window_update, StreamId, Increment}) ->
    encode_window_update(StreamId, Increment);
encode({continuation, StreamId, HeaderBlock, EndHeaders}) ->
    encode_continuation(StreamId, HeaderBlock, EndHeaders).

%% @doc Encode a DATA frame.
-spec encode_data(stream_id(), binary(), boolean()) -> iodata().
encode_data(StreamId, Data, EndStream) ->
    Length = byte_size(Data),
    Flags = case EndStream of true -> ?FLAG_END_STREAM; false -> 0 end,
    [<<Length:24, ?FRAME_DATA:8, Flags:8, 0:1, StreamId:31>>, Data].

%% @doc Encode a HEADERS frame.
-spec encode_headers(stream_id(), binary(), boolean()) -> iodata().
encode_headers(StreamId, HeaderBlock, EndStream) ->
    encode_headers(StreamId, HeaderBlock, EndStream, true).

-spec encode_headers(stream_id(), binary(), boolean(), boolean()) -> iodata().
encode_headers(StreamId, HeaderBlock, EndStream, EndHeaders) ->
    Length = byte_size(HeaderBlock),
    Flags = (case EndStream of true -> ?FLAG_END_STREAM; false -> 0 end) bor
            (case EndHeaders of true -> ?FLAG_END_HEADERS; false -> 0 end),
    [<<Length:24, ?FRAME_HEADERS:8, Flags:8, 0:1, StreamId:31>>, HeaderBlock].

encode_headers_with_priority(StreamId, HeaderBlock, EndStream, EndHeaders, {Exclusive, StreamDep, Weight}) ->
    E = case Exclusive of true -> 1; false -> 0 end,
    PriorityData = <<E:1, StreamDep:31, (Weight - 1):8>>,
    Payload = <<PriorityData/binary, HeaderBlock/binary>>,
    Length = byte_size(Payload),
    Flags = ?FLAG_PRIORITY bor
            (case EndStream of true -> ?FLAG_END_STREAM; false -> 0 end) bor
            (case EndHeaders of true -> ?FLAG_END_HEADERS; false -> 0 end),
    [<<Length:24, ?FRAME_HEADERS:8, Flags:8, 0:1, StreamId:31>>, Payload].

%% @doc Encode a PRIORITY frame.
-spec encode_priority(stream_id(), boolean(), stream_id(), 1..256) -> iodata().
encode_priority(StreamId, Exclusive, StreamDep, Weight) ->
    E = case Exclusive of true -> 1; false -> 0 end,
    Payload = <<E:1, StreamDep:31, (Weight - 1):8>>,
    [<<5:24, ?FRAME_PRIORITY:8, 0:8, 0:1, StreamId:31>>, Payload].

%% @doc Encode a RST_STREAM frame.
-spec encode_rst_stream(stream_id(), error_code()) -> iodata().
encode_rst_stream(StreamId, ErrorCode) ->
    [<<4:24, ?FRAME_RST_STREAM:8, 0:8, 0:1, StreamId:31, ErrorCode:32>>].

%% @doc Encode a SETTINGS frame.
-spec encode_settings(settings()) -> iodata().
encode_settings(Settings) ->
    Payload = encode_settings_payload(Settings),
    Length = byte_size(Payload),
    [<<Length:24, ?FRAME_SETTINGS:8, 0:8, 0:1, 0:31>>, Payload].

encode_settings_payload(Settings) ->
    lists:foldl(fun({Key, Value}, Acc) ->
        Id = settings_key_to_id(Key),
        <<Acc/binary, Id:16, Value:32>>
    end, <<>>, maps:to_list(Settings)).

settings_key_to_id(header_table_size) -> ?SETTINGS_HEADER_TABLE_SIZE;
settings_key_to_id(enable_push) -> ?SETTINGS_ENABLE_PUSH;
settings_key_to_id(max_concurrent_streams) -> ?SETTINGS_MAX_CONCURRENT_STREAMS;
settings_key_to_id(initial_window_size) -> ?SETTINGS_INITIAL_WINDOW_SIZE;
settings_key_to_id(max_frame_size) -> ?SETTINGS_MAX_FRAME_SIZE;
settings_key_to_id(max_header_list_size) -> ?SETTINGS_MAX_HEADER_LIST_SIZE.

%% @doc Encode a SETTINGS ACK frame.
-spec encode_settings_ack() -> binary().
encode_settings_ack() ->
    <<0:24, ?FRAME_SETTINGS:8, ?FLAG_ACK:8, 0:1, 0:31>>.

%% @doc Encode a PUSH_PROMISE frame.
-spec encode_push_promise(stream_id(), stream_id(), binary(), boolean()) -> iodata().
encode_push_promise(StreamId, PromisedStreamId, HeaderBlock, EndHeaders) ->
    Payload = <<0:1, PromisedStreamId:31, HeaderBlock/binary>>,
    Length = byte_size(Payload),
    Flags = case EndHeaders of true -> ?FLAG_END_HEADERS; false -> 0 end,
    [<<Length:24, ?FRAME_PUSH_PROMISE:8, Flags:8, 0:1, StreamId:31>>, Payload].

%% @doc Encode a PING frame.
-spec encode_ping(binary()) -> iodata().
encode_ping(OpaqueData) when byte_size(OpaqueData) =:= 8 ->
    [<<8:24, ?FRAME_PING:8, 0:8, 0:1, 0:31>>, OpaqueData].

%% @doc Encode a PING ACK frame.
-spec encode_ping_ack(binary()) -> iodata().
encode_ping_ack(OpaqueData) when byte_size(OpaqueData) =:= 8 ->
    [<<8:24, ?FRAME_PING:8, ?FLAG_ACK:8, 0:1, 0:31>>, OpaqueData].

%% @doc Encode a GOAWAY frame.
-spec encode_goaway(stream_id(), error_code(), binary()) -> iodata().
encode_goaway(LastStreamId, ErrorCode, DebugData) ->
    Payload = <<0:1, LastStreamId:31, ErrorCode:32, DebugData/binary>>,
    Length = byte_size(Payload),
    [<<Length:24, ?FRAME_GOAWAY:8, 0:8, 0:1, 0:31>>, Payload].

%% @doc Encode a WINDOW_UPDATE frame.
-spec encode_window_update(stream_id(), pos_integer()) -> iodata().
encode_window_update(StreamId, Increment) when Increment > 0 ->
    [<<4:24, ?FRAME_WINDOW_UPDATE:8, 0:8, 0:1, StreamId:31, 0:1, Increment:31>>].

%% @doc Encode a CONTINUATION frame.
-spec encode_continuation(stream_id(), binary(), boolean()) -> iodata().
encode_continuation(StreamId, HeaderBlock, EndHeaders) ->
    Length = byte_size(HeaderBlock),
    Flags = case EndHeaders of true -> ?FLAG_END_HEADERS; false -> 0 end,
    [<<Length:24, ?FRAME_CONTINUATION:8, Flags:8, 0:1, StreamId:31>>, HeaderBlock].

%% ===================================================================
%% Decoding
%% ===================================================================

%% @doc Decode a frame from binary.
-spec decode(binary()) -> decode_result().
decode(Data) when byte_size(Data) < 9 ->
    {more, 9 - byte_size(Data)};
decode(<<Length:24, Type:8, Flags:8, _:1, StreamId:31, Rest/binary>>) ->
    case byte_size(Rest) >= Length of
        true ->
            <<Payload:Length/binary, Remaining/binary>> = Rest,
            decode_frame(Type, Flags, StreamId, Payload, Remaining);
        false ->
            {more, Length - byte_size(Rest)}
    end.

decode_frame(?FRAME_DATA, Flags, StreamId, Payload, Rest) ->
    EndStream = (Flags band ?FLAG_END_STREAM) =/= 0,
    {Data, _Padding} = strip_padding(Flags, Payload),
    {ok, {data, StreamId, Data, EndStream}, Rest};

decode_frame(?FRAME_HEADERS, Flags, StreamId, Payload, Rest) ->
    EndStream = (Flags band ?FLAG_END_STREAM) =/= 0,
    EndHeaders = (Flags band ?FLAG_END_HEADERS) =/= 0,
    HasPriority = (Flags band ?FLAG_PRIORITY) =/= 0,
    {Data, _Padding} = strip_padding(Flags, Payload),
    case HasPriority of
        true when byte_size(Data) >= 5 ->
            <<E:1, StreamDep:31, Weight:8, HeaderBlock/binary>> = Data,
            Exclusive = E =:= 1,
            Priority = {Exclusive, StreamDep, Weight + 1},
            {ok, {headers, StreamId, HeaderBlock, EndStream, EndHeaders, Priority}, Rest};
        true ->
            {error, frame_size_error};
        false ->
            {ok, {headers, StreamId, Data, EndStream, EndHeaders}, Rest}
    end;

decode_frame(?FRAME_PRIORITY, _Flags, StreamId, <<E:1, StreamDep:31, Weight:8>>, Rest) ->
    Exclusive = E =:= 1,
    {ok, {priority, StreamId, {Exclusive, StreamDep, Weight + 1}}, Rest};
decode_frame(?FRAME_PRIORITY, _Flags, _StreamId, _Payload, _Rest) ->
    {error, frame_size_error};

decode_frame(?FRAME_RST_STREAM, _Flags, StreamId, <<ErrorCode:32>>, Rest) ->
    {ok, {rst_stream, StreamId, ErrorCode}, Rest};
decode_frame(?FRAME_RST_STREAM, _Flags, _StreamId, _Payload, _Rest) ->
    {error, frame_size_error};

decode_frame(?FRAME_SETTINGS, Flags, 0, Payload, Rest) ->
    IsAck = (Flags band ?FLAG_ACK) =/= 0,
    case IsAck of
        true when byte_size(Payload) =:= 0 ->
            {ok, {settings_ack}, Rest};
        true ->
            {error, frame_size_error};
        false ->
            case decode_settings_payload(Payload) of
                {ok, Settings} ->
                    {ok, {settings, Settings}, Rest};
                {error, Reason} ->
                    {error, Reason}
            end
    end;
decode_frame(?FRAME_SETTINGS, _Flags, _StreamId, _Payload, _Rest) ->
    {error, protocol_error};

decode_frame(?FRAME_PUSH_PROMISE, Flags, StreamId, Payload, Rest) ->
    EndHeaders = (Flags band ?FLAG_END_HEADERS) =/= 0,
    {Data, _Padding} = strip_padding(Flags, Payload),
    case Data of
        <<_:1, PromisedStreamId:31, HeaderBlock/binary>> ->
            {ok, {push_promise, StreamId, PromisedStreamId, HeaderBlock, EndHeaders}, Rest};
        _ ->
            {error, frame_size_error}
    end;

decode_frame(?FRAME_PING, Flags, 0, OpaqueData, Rest) when byte_size(OpaqueData) =:= 8 ->
    IsAck = (Flags band ?FLAG_ACK) =/= 0,
    case IsAck of
        true -> {ok, {ping_ack, OpaqueData}, Rest};
        false -> {ok, {ping, OpaqueData}, Rest}
    end;
decode_frame(?FRAME_PING, _Flags, 0, _Payload, _Rest) ->
    {error, frame_size_error};
decode_frame(?FRAME_PING, _Flags, _StreamId, _Payload, _Rest) ->
    {error, protocol_error};

decode_frame(?FRAME_GOAWAY, _Flags, 0, Payload, Rest) when byte_size(Payload) >= 8 ->
    <<_:1, LastStreamId:31, ErrorCode:32, DebugData/binary>> = Payload,
    {ok, {goaway, LastStreamId, ErrorCode, DebugData}, Rest};
decode_frame(?FRAME_GOAWAY, _Flags, 0, _Payload, _Rest) ->
    {error, frame_size_error};
decode_frame(?FRAME_GOAWAY, _Flags, _StreamId, _Payload, _Rest) ->
    {error, protocol_error};

decode_frame(?FRAME_WINDOW_UPDATE, _Flags, StreamId, <<_:1, Increment:31>>, Rest) when Increment > 0 ->
    {ok, {window_update, StreamId, Increment}, Rest};
decode_frame(?FRAME_WINDOW_UPDATE, _Flags, _StreamId, <<_:1, 0:31>>, _Rest) ->
    {error, protocol_error};
decode_frame(?FRAME_WINDOW_UPDATE, _Flags, _StreamId, _Payload, _Rest) ->
    {error, frame_size_error};

decode_frame(?FRAME_CONTINUATION, Flags, StreamId, Payload, Rest) ->
    EndHeaders = (Flags band ?FLAG_END_HEADERS) =/= 0,
    {ok, {continuation, StreamId, Payload, EndHeaders}, Rest};

decode_frame(_Type, _Flags, _StreamId, _Payload, _Rest) ->
    %% Unknown frame type - MUST be ignored per spec
    {error, unknown_frame_type}.

%% Strip padding from payload if PADDED flag is set
strip_padding(Flags, Payload) when (Flags band ?FLAG_PADDED) =/= 0, byte_size(Payload) > 0 ->
    <<PadLength:8, Rest/binary>> = Payload,
    DataLength = byte_size(Rest) - PadLength,
    case DataLength >= 0 of
        true ->
            <<Data:DataLength/binary, _Padding:PadLength/binary>> = Rest,
            {Data, PadLength};
        false ->
            {<<>>, 0}  %% Invalid padding
    end;
strip_padding(_Flags, Payload) ->
    {Payload, 0}.

%% @doc Decode SETTINGS payload to map.
-spec decode_settings_payload(binary()) -> {ok, settings()} | {error, term()}.
decode_settings_payload(Payload) ->
    decode_settings_payload(Payload, #{}).

decode_settings_payload(<<>>, Acc) ->
    {ok, Acc};
decode_settings_payload(<<Id:16, Value:32, Rest/binary>>, Acc) ->
    case settings_id_to_key(Id) of
        unknown ->
            %% Unknown settings MUST be ignored
            decode_settings_payload(Rest, Acc);
        Key ->
            decode_settings_payload(Rest, Acc#{Key => Value})
    end;
decode_settings_payload(_Invalid, _Acc) ->
    {error, frame_size_error}.

settings_id_to_key(?SETTINGS_HEADER_TABLE_SIZE) -> header_table_size;
settings_id_to_key(?SETTINGS_ENABLE_PUSH) -> enable_push;
settings_id_to_key(?SETTINGS_MAX_CONCURRENT_STREAMS) -> max_concurrent_streams;
settings_id_to_key(?SETTINGS_INITIAL_WINDOW_SIZE) -> initial_window_size;
settings_id_to_key(?SETTINGS_MAX_FRAME_SIZE) -> max_frame_size;
settings_id_to_key(?SETTINGS_MAX_HEADER_LIST_SIZE) -> max_header_list_size;
settings_id_to_key(_) -> unknown.
