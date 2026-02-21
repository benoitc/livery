%% @doc Unit tests for HTTP/3 frame encoding/decoding.
-module(livery_h3_frame_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% Variable-length integer encoding (RFC 9000 Section 16)
%% ===================================================================

encode_varint_1_byte_test() ->
    %% Values 0-63 fit in 1 byte (6-bit prefix)
    ?assertEqual(<<0:2, 0:6>>, livery_h3_frame:encode_varint(0)),
    ?assertEqual(<<0:2, 37:6>>, livery_h3_frame:encode_varint(37)),
    ?assertEqual(<<0:2, 63:6>>, livery_h3_frame:encode_varint(63)).

encode_varint_2_byte_test() ->
    %% Values 64-16383 fit in 2 bytes (14-bit prefix)
    ?assertEqual(<<1:2, 64:14>>, livery_h3_frame:encode_varint(64)),
    ?assertEqual(<<1:2, 1000:14>>, livery_h3_frame:encode_varint(1000)),
    ?assertEqual(<<1:2, 16383:14>>, livery_h3_frame:encode_varint(16383)).

encode_varint_4_byte_test() ->
    %% Values 16384-1073741823 fit in 4 bytes (30-bit prefix)
    ?assertEqual(<<2:2, 16384:30>>, livery_h3_frame:encode_varint(16384)),
    ?assertEqual(<<2:2, 1000000:30>>, livery_h3_frame:encode_varint(1000000)).

encode_varint_8_byte_test() ->
    %% Large values fit in 8 bytes (62-bit prefix)
    LargeVal = 1073741824,  %% Just above 4-byte threshold
    ?assertEqual(<<3:2, LargeVal:62>>, livery_h3_frame:encode_varint(LargeVal)).

decode_varint_test() ->
    %% Test round-trip for various values
    Values = [0, 1, 63, 64, 1000, 16383, 16384, 1000000],
    lists:foreach(fun(V) ->
        Encoded = livery_h3_frame:encode_varint(V),
        {ok, Decoded, <<>>} = livery_h3_frame:decode_varint(Encoded),
        ?assertEqual(V, Decoded)
    end, Values).

decode_varint_with_rest_test() ->
    Encoded = <<0:2, 42:6, "rest">>,
    {ok, 42, <<"rest">>} = livery_h3_frame:decode_varint(Encoded).

decode_varint_incomplete_test() ->
    %% Need 2 bytes but only have 1
    incomplete = livery_h3_frame:decode_varint(<<1:2, 0:6>>).

%% ===================================================================
%% DATA frame tests
%% ===================================================================

encode_decode_data_frame_test() ->
    Payload = <<"Hello, HTTP/3!">>,
    Encoded = livery_h3_frame:encode_data(Payload),
    {ok, {data, Decoded}, <<>>} = livery_h3_frame:decode(Encoded),
    ?assertEqual(Payload, Decoded).

encode_decode_data_empty_test() ->
    Encoded = livery_h3_frame:encode_data(<<>>),
    {ok, {data, <<>>}, <<>>} = livery_h3_frame:decode(Encoded).

encode_decode_data_large_test() ->
    Payload = binary:copy(<<"x">>, 10000),
    Encoded = livery_h3_frame:encode_data(Payload),
    {ok, {data, Decoded}, <<>>} = livery_h3_frame:decode(Encoded),
    ?assertEqual(Payload, Decoded).

%% ===================================================================
%% HEADERS frame tests
%% ===================================================================

encode_decode_headers_frame_test() ->
    HeaderBlock = <<"encoded-headers">>,
    Encoded = livery_h3_frame:encode_headers(HeaderBlock),
    {ok, {headers, Decoded}, <<>>} = livery_h3_frame:decode(Encoded),
    ?assertEqual(HeaderBlock, Decoded).

%% ===================================================================
%% SETTINGS frame tests
%% ===================================================================

encode_decode_settings_test() ->
    Settings = #{
        qpack_max_table_capacity => 4096,
        max_field_section_size => 65536
    },
    Encoded = livery_h3_frame:encode_settings(Settings),
    {ok, {settings, Decoded}, <<>>} = livery_h3_frame:decode(Encoded),
    ?assertEqual(4096, maps:get(qpack_max_table_capacity, Decoded)),
    ?assertEqual(65536, maps:get(max_field_section_size, Decoded)).

encode_decode_empty_settings_test() ->
    Encoded = livery_h3_frame:encode_settings(#{}),
    {ok, {settings, Decoded}, <<>>} = livery_h3_frame:decode(Encoded),
    ?assertEqual(#{}, Decoded).

default_settings_test() ->
    Settings = livery_h3_frame:default_settings(),
    ?assertEqual(0, maps:get(qpack_max_table_capacity, Settings)),
    ?assertEqual(65536, maps:get(max_field_section_size, Settings)),
    ?assertEqual(0, maps:get(qpack_blocked_streams, Settings)).

%% ===================================================================
%% GOAWAY frame tests
%% ===================================================================

encode_decode_goaway_test() ->
    StreamId = 12,
    Encoded = livery_h3_frame:encode_goaway(StreamId),
    {ok, {goaway, Decoded}, <<>>} = livery_h3_frame:decode(Encoded),
    ?assertEqual(StreamId, Decoded).

encode_decode_goaway_zero_test() ->
    Encoded = livery_h3_frame:encode_goaway(0),
    {ok, {goaway, 0}, <<>>} = livery_h3_frame:decode(Encoded).

%% ===================================================================
%% MAX_PUSH_ID frame tests
%% ===================================================================

encode_decode_max_push_id_test() ->
    PushId = 100,
    Encoded = livery_h3_frame:encode_max_push_id(PushId),
    {ok, {max_push_id, Decoded}, <<>>} = livery_h3_frame:decode(Encoded),
    ?assertEqual(PushId, Decoded).

%% ===================================================================
%% Generic encode/decode API
%% ===================================================================

encode_data_via_generic_test() ->
    Frame = {data, <<"test">>},
    Encoded = livery_h3_frame:encode(Frame),
    {ok, Decoded, <<>>} = livery_h3_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_headers_via_generic_test() ->
    Frame = {headers, <<"header-block">>},
    Encoded = livery_h3_frame:encode(Frame),
    {ok, Decoded, <<>>} = livery_h3_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_settings_via_generic_test() ->
    Frame = {settings, #{qpack_max_table_capacity => 1024}},
    Encoded = livery_h3_frame:encode(Frame),
    {ok, {settings, Decoded}, <<>>} = livery_h3_frame:decode(Encoded),
    ?assertEqual(1024, maps:get(qpack_max_table_capacity, Decoded)).

encode_goaway_via_generic_test() ->
    Frame = {goaway, 8},
    Encoded = livery_h3_frame:encode(Frame),
    {ok, Decoded, <<>>} = livery_h3_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

%% ===================================================================
%% Partial frame tests
%% ===================================================================

decode_partial_type_test() ->
    %% Not enough data for type
    {more, _} = livery_h3_frame:decode(<<>>).

decode_partial_length_test() ->
    %% Type present but not length
    {more, _} = livery_h3_frame:decode(<<0:2, 0:6>>).

decode_partial_payload_test() ->
    %% Full header but incomplete payload
    %% Type=0 (DATA), Length=10, but only 5 bytes of payload
    TypeLen = <<0:2, 0:6, 0:2, 10:6>>,
    Partial = <<TypeLen/binary, "hello">>,  %% Only 5 bytes, need 10
    {more, N} = livery_h3_frame:decode(Partial),
    ?assertEqual(5, N).

%% ===================================================================
%% Multiple frames test
%% ===================================================================

decode_multiple_frames_test() ->
    Frame1 = {data, <<"first">>},
    Frame2 = {data, <<"second">>},
    Encoded1 = livery_h3_frame:encode(Frame1),
    Encoded2 = livery_h3_frame:encode(Frame2),
    Combined = <<Encoded1/binary, Encoded2/binary>>,

    {ok, Decoded1, Rest1} = livery_h3_frame:decode(Combined),
    ?assertEqual(Frame1, Decoded1),

    {ok, Decoded2, Rest2} = livery_h3_frame:decode(Rest1),
    ?assertEqual(Frame2, Decoded2),
    ?assertEqual(<<>>, Rest2).

decode_all_test() ->
    Frames = [{data, <<"one">>}, {data, <<"two">>}, {data, <<"three">>}],
    Combined = iolist_to_binary([livery_h3_frame:encode(F) || F <- Frames]),
    {ok, Decoded, <<>>} = livery_h3_frame:decode_all(Combined),
    ?assertEqual(Frames, Decoded).

decode_all_with_remainder_test() ->
    Frame = {data, <<"complete">>},
    Partial = <<0:2, 0:6, 0:2, 10:6, "short">>,  %% Incomplete frame
    Combined = <<(livery_h3_frame:encode(Frame))/binary, Partial/binary>>,
    {ok, Decoded, Rest} = livery_h3_frame:decode_all(Combined),
    ?assertEqual([Frame], Decoded),
    ?assertEqual(Partial, Rest).

%% ===================================================================
%% Settings payload helpers
%% ===================================================================

encode_settings_payload_test() ->
    Settings = #{qpack_max_table_capacity => 100},
    Payload = livery_h3_frame:encode_settings_payload(Settings),
    {ok, Decoded} = livery_h3_frame:decode_settings_payload(Payload),
    ?assertEqual(100, maps:get(qpack_max_table_capacity, Decoded)).

decode_settings_payload_empty_test() ->
    {ok, #{}} = livery_h3_frame:decode_settings_payload(<<>>).

%% ===================================================================
%% Unknown frame types
%% ===================================================================

decode_unknown_frame_type_test() ->
    %% Type 0xFF is unknown, should be decoded as {unknown, Type, Payload}
    Type = 255,
    Payload = <<"unknown-payload">>,
    TypeEnc = livery_h3_frame:encode_varint(Type),
    LenEnc = livery_h3_frame:encode_varint(byte_size(Payload)),
    Encoded = <<TypeEnc/binary, LenEnc/binary, Payload/binary>>,
    {ok, {unknown, Type, Payload}, <<>>} = livery_h3_frame:decode(Encoded).
