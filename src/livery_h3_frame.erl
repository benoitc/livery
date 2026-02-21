%% @doc HTTP/3 frame encoding and decoding (RFC 9114).
%%
%% HTTP/3 frames use QUIC variable-length integer encoding for
%% frame type and length fields.
-module(livery_h3_frame).

-export([
    %% Frame encoding
    encode/1,
    encode_data/1,
    encode_headers/1,
    encode_settings/1,
    encode_goaway/1,
    encode_max_push_id/1,
    %% Frame decoding
    decode/1,
    decode_all/1,
    %% Variable-length integer encoding
    encode_varint/1,
    decode_varint/1,
    %% Settings helpers
    default_settings/0,
    encode_settings_payload/1,
    decode_settings_payload/1
]).

%% HTTP/3 frame types (RFC 9114 Section 7.2)
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

%% HTTP/3 settings identifiers
-define(SETTINGS_QPACK_MAX_TABLE_CAPACITY, 16#01).
-define(SETTINGS_MAX_FIELD_SECTION_SIZE,   16#06).
-define(SETTINGS_QPACK_BLOCKED_STREAMS,    16#07).
-define(SETTINGS_ENABLE_CONNECT_PROTOCOL,  16#08).

-type frame() :: {data, binary()}
               | {headers, binary()}
               | {cancel_push, non_neg_integer()}
               | {settings, map()}
               | {push_promise, non_neg_integer(), binary()}
               | {goaway, non_neg_integer()}
               | {max_push_id, non_neg_integer()}
               | {unknown, non_neg_integer(), binary()}.

-export_type([frame/0]).

%%====================================================================
%% Frame Encoding
%%====================================================================

%% @doc Encode an HTTP/3 frame to binary.
-spec encode(frame()) -> binary().
encode({data, Payload}) ->
    encode_data(Payload);
encode({headers, Payload}) ->
    encode_headers(Payload);
encode({cancel_push, PushId}) ->
    encode_frame(?H3_CANCEL_PUSH, encode_varint(PushId));
encode({settings, Settings}) ->
    encode_settings(Settings);
encode({push_promise, PushId, HeaderBlock}) ->
    PushIdEnc = encode_varint(PushId),
    encode_frame(?H3_PUSH_PROMISE, <<PushIdEnc/binary, HeaderBlock/binary>>);
encode({goaway, StreamId}) ->
    encode_goaway(StreamId);
encode({max_push_id, PushId}) ->
    encode_max_push_id(PushId).

%% @doc Encode a DATA frame.
-spec encode_data(binary()) -> binary().
encode_data(Payload) ->
    encode_frame(?H3_DATA, Payload).

%% @doc Encode a HEADERS frame.
-spec encode_headers(binary()) -> binary().
encode_headers(HeaderBlock) ->
    encode_frame(?H3_HEADERS, HeaderBlock).

%% @doc Encode a SETTINGS frame.
-spec encode_settings(map()) -> binary().
encode_settings(Settings) ->
    Payload = encode_settings_payload(Settings),
    encode_frame(?H3_SETTINGS, Payload).

%% @doc Encode a GOAWAY frame.
-spec encode_goaway(non_neg_integer()) -> binary().
encode_goaway(StreamId) ->
    encode_frame(?H3_GOAWAY, encode_varint(StreamId)).

%% @doc Encode a MAX_PUSH_ID frame.
-spec encode_max_push_id(non_neg_integer()) -> binary().
encode_max_push_id(PushId) ->
    encode_frame(?H3_MAX_PUSH_ID, encode_varint(PushId)).

%% Internal: encode a frame with type and payload
encode_frame(Type, Payload) ->
    TypeEnc = encode_varint(Type),
    LenEnc = encode_varint(byte_size(Payload)),
    <<TypeEnc/binary, LenEnc/binary, Payload/binary>>.

%%====================================================================
%% Frame Decoding
%%====================================================================

%% @doc Decode an HTTP/3 frame from binary.
%% Returns {ok, Frame, Rest} | {more, N} | {error, Reason}.
-spec decode(binary()) -> {ok, frame(), binary()} | {more, non_neg_integer()} | {error, term()}.
decode(Data) ->
    case decode_varint(Data) of
        {ok, Type, Rest1} ->
            case decode_varint(Rest1) of
                {ok, Length, Rest2} ->
                    case byte_size(Rest2) >= Length of
                        true ->
                            <<Payload:Length/binary, Rest3/binary>> = Rest2,
                            Frame = decode_frame_payload(Type, Payload),
                            {ok, Frame, Rest3};
                        false ->
                            {more, Length - byte_size(Rest2)}
                    end;
                incomplete ->
                    {more, 1}
            end;
        incomplete ->
            {more, 1}
    end.

%% @doc Decode all frames from binary buffer.
-spec decode_all(binary()) -> {ok, [frame()], binary()} | {error, term()}.
decode_all(Data) ->
    decode_all(Data, []).

decode_all(<<>>, Acc) ->
    {ok, lists:reverse(Acc), <<>>};
decode_all(Data, Acc) ->
    case decode(Data) of
        {ok, Frame, Rest} ->
            decode_all(Rest, [Frame | Acc]);
        {more, _} ->
            {ok, lists:reverse(Acc), Data};
        {error, _} = Error ->
            Error
    end.

%% Internal: decode frame payload by type
decode_frame_payload(?H3_DATA, Payload) ->
    {data, Payload};
decode_frame_payload(?H3_HEADERS, Payload) ->
    {headers, Payload};
decode_frame_payload(?H3_CANCEL_PUSH, Payload) ->
    case decode_varint(Payload) of
        {ok, PushId, _} -> {cancel_push, PushId};
        _ -> {cancel_push, 0}
    end;
decode_frame_payload(?H3_SETTINGS, Payload) ->
    {ok, Settings} = decode_settings_payload(Payload),
    {settings, Settings};
decode_frame_payload(?H3_PUSH_PROMISE, Payload) ->
    case decode_varint(Payload) of
        {ok, PushId, HeaderBlock} -> {push_promise, PushId, HeaderBlock};
        _ -> {push_promise, 0, <<>>}
    end;
decode_frame_payload(?H3_GOAWAY, Payload) ->
    case decode_varint(Payload) of
        {ok, StreamId, _} -> {goaway, StreamId};
        _ -> {goaway, 0}
    end;
decode_frame_payload(?H3_MAX_PUSH_ID, Payload) ->
    case decode_varint(Payload) of
        {ok, PushId, _} -> {max_push_id, PushId};
        _ -> {max_push_id, 0}
    end;
decode_frame_payload(Type, Payload) ->
    %% Unknown or reserved frame type
    {unknown, Type, Payload}.

%%====================================================================
%% Variable-Length Integer Encoding (RFC 9000 Section 16)
%%====================================================================

%% @doc Encode a variable-length integer.
-spec encode_varint(non_neg_integer()) -> binary().
encode_varint(N) when N < 64 ->
    <<0:2, N:6>>;
encode_varint(N) when N < 16384 ->
    <<1:2, N:14>>;
encode_varint(N) when N < 1073741824 ->
    <<2:2, N:30>>;
encode_varint(N) when N < 4611686018427387904 ->
    <<3:2, N:62>>.

%% @doc Decode a variable-length integer.
-spec decode_varint(binary()) -> {ok, non_neg_integer(), binary()} | incomplete.
decode_varint(<<0:2, N:6, Rest/binary>>) ->
    {ok, N, Rest};
decode_varint(<<1:2, N:14, Rest/binary>>) ->
    {ok, N, Rest};
decode_varint(<<2:2, N:30, Rest/binary>>) ->
    {ok, N, Rest};
decode_varint(<<3:2, N:62, Rest/binary>>) ->
    {ok, N, Rest};
decode_varint(_) ->
    incomplete.

%%====================================================================
%% Settings Helpers
%%====================================================================

%% @doc Return default HTTP/3 settings.
-spec default_settings() -> map().
default_settings() ->
    #{
        qpack_max_table_capacity => 0,
        max_field_section_size => 65536,
        qpack_blocked_streams => 0,
        enable_connect_protocol => 1
    }.

%% @doc Encode settings map to SETTINGS frame payload.
-spec encode_settings_payload(map()) -> binary().
encode_settings_payload(Settings) ->
    encode_settings_pairs(maps:to_list(Settings), <<>>).

encode_settings_pairs([], Acc) ->
    Acc;
encode_settings_pairs([{Key, Value} | Rest], Acc) ->
    Id = setting_to_id(Key),
    IdEnc = encode_varint(Id),
    ValueEnc = encode_varint(Value),
    encode_settings_pairs(Rest, <<Acc/binary, IdEnc/binary, ValueEnc/binary>>).

%% @doc Decode SETTINGS frame payload to settings map.
-spec decode_settings_payload(binary()) -> {ok, map()} | {error, term()}.
decode_settings_payload(Data) ->
    decode_settings_pairs(Data, #{}).

decode_settings_pairs(<<>>, Acc) ->
    {ok, Acc};
decode_settings_pairs(Data, Acc) ->
    case decode_varint(Data) of
        {ok, Id, Rest1} ->
            case decode_varint(Rest1) of
                {ok, Value, Rest2} ->
                    Key = id_to_setting(Id),
                    decode_settings_pairs(Rest2, Acc#{Key => Value});
                incomplete ->
                    {ok, Acc}
            end;
        incomplete ->
            {ok, Acc}
    end.

setting_to_id(qpack_max_table_capacity) -> ?SETTINGS_QPACK_MAX_TABLE_CAPACITY;
setting_to_id(max_field_section_size) -> ?SETTINGS_MAX_FIELD_SECTION_SIZE;
setting_to_id(qpack_blocked_streams) -> ?SETTINGS_QPACK_BLOCKED_STREAMS;
setting_to_id(enable_connect_protocol) -> ?SETTINGS_ENABLE_CONNECT_PROTOCOL;
setting_to_id(Id) when is_integer(Id) -> Id.

id_to_setting(?SETTINGS_QPACK_MAX_TABLE_CAPACITY) -> qpack_max_table_capacity;
id_to_setting(?SETTINGS_MAX_FIELD_SECTION_SIZE) -> max_field_section_size;
id_to_setting(?SETTINGS_QPACK_BLOCKED_STREAMS) -> qpack_blocked_streams;
id_to_setting(?SETTINGS_ENABLE_CONNECT_PROTOCOL) -> enable_connect_protocol;
id_to_setting(Id) -> Id.
