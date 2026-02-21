%% @doc Unit tests for HTTP/2 frame encoding/decoding.
-module(livery_h2_frame_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% Constants
%% ===================================================================

frame_header_size_test() ->
    ?assertEqual(9, livery_h2_frame:frame_header_size()).

default_settings_test() ->
    Settings = livery_h2_frame:default_settings(),
    ?assertEqual(4096, maps:get(header_table_size, Settings)),
    ?assertEqual(16384, maps:get(max_frame_size, Settings)).

%% ===================================================================
%% DATA frame tests
%% ===================================================================

encode_decode_data_test() ->
    Frame = {data, 1, <<"hello">>, false},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_data_end_stream_test() ->
    Frame = {data, 3, <<"world">>, true},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_data_empty_test() ->
    Frame = {data, 1, <<>>, true},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

%% ===================================================================
%% HEADERS frame tests
%% ===================================================================

encode_decode_headers_test() ->
    Frame = {headers, 1, <<"header-block">>, false, true},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_headers_end_stream_test() ->
    Frame = {headers, 1, <<"header-block">>, true, true},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_headers_with_priority_test() ->
    Priority = {false, 0, 16},
    Frame = {headers, 1, <<"header-block">>, false, true, Priority},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_headers_exclusive_priority_test() ->
    Priority = {true, 3, 256},
    Frame = {headers, 5, <<"data">>, true, true, Priority},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

%% ===================================================================
%% PRIORITY frame tests
%% ===================================================================

encode_decode_priority_test() ->
    Frame = {priority, 3, {false, 1, 16}},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_priority_exclusive_test() ->
    Frame = {priority, 5, {true, 3, 256}},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

%% ===================================================================
%% RST_STREAM frame tests
%% ===================================================================

encode_decode_rst_stream_test() ->
    Frame = {rst_stream, 1, 0},  %% NO_ERROR
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_rst_stream_cancel_test() ->
    Frame = {rst_stream, 3, 8},  %% CANCEL
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

%% ===================================================================
%% SETTINGS frame tests
%% ===================================================================

encode_decode_settings_test() ->
    Settings = #{
        header_table_size => 4096,
        max_concurrent_streams => 100,
        initial_window_size => 65535
    },
    Frame = {settings, Settings},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    {settings, DecodedSettings} = Decoded,
    ?assertEqual(maps:get(header_table_size, Settings), maps:get(header_table_size, DecodedSettings)),
    ?assertEqual(maps:get(max_concurrent_streams, Settings), maps:get(max_concurrent_streams, DecodedSettings)),
    ?assertEqual(maps:get(initial_window_size, Settings), maps:get(initial_window_size, DecodedSettings)).

encode_decode_settings_ack_test() ->
    Frame = {settings_ack},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_empty_settings_test() ->
    Frame = {settings, #{}},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, {settings, Decoded}, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(#{}, Decoded).

%% ===================================================================
%% PUSH_PROMISE frame tests
%% ===================================================================

encode_decode_push_promise_test() ->
    Frame = {push_promise, 1, 2, <<"header-block">>},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    %% Decoded includes EndHeaders flag
    ?assertMatch({push_promise, 1, 2, <<"header-block">>, true}, Decoded).

%% ===================================================================
%% PING frame tests
%% ===================================================================

encode_decode_ping_test() ->
    OpaqueData = <<1,2,3,4,5,6,7,8>>,
    Frame = {ping, OpaqueData},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_ping_ack_test() ->
    OpaqueData = <<1,2,3,4,5,6,7,8>>,
    Frame = {ping_ack, OpaqueData},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

%% ===================================================================
%% GOAWAY frame tests
%% ===================================================================

encode_decode_goaway_test() ->
    Frame = {goaway, 5, 0, <<>>},  %% NO_ERROR, no debug data
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_goaway_with_debug_test() ->
    Frame = {goaway, 7, 1, <<"connection error">>},  %% PROTOCOL_ERROR
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

%% ===================================================================
%% WINDOW_UPDATE frame tests
%% ===================================================================

encode_decode_window_update_test() ->
    Frame = {window_update, 0, 65535},  %% Connection-level
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_window_update_stream_test() ->
    Frame = {window_update, 3, 1000},  %% Stream-level
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

%% ===================================================================
%% CONTINUATION frame tests
%% ===================================================================

encode_decode_continuation_test() ->
    Frame = {continuation, 1, <<"more-headers">>, false},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

encode_decode_continuation_end_headers_test() ->
    Frame = {continuation, 1, <<"final-headers">>, true},
    Encoded = iolist_to_binary(livery_h2_frame:encode(Frame)),
    {ok, Decoded, <<>>} = livery_h2_frame:decode(Encoded),
    ?assertEqual(Frame, Decoded).

%% ===================================================================
%% Partial frame tests
%% ===================================================================

decode_partial_header_test() ->
    %% Less than 9 bytes
    {more, N} = livery_h2_frame:decode(<<1,2,3,4,5>>),
    ?assertEqual(4, N).

decode_partial_payload_test() ->
    %% Full header but incomplete payload
    %% Frame header: length=10, type=0 (DATA), flags=0, stream_id=1
    Header = <<10:24, 0:8, 0:8, 0:1, 1:31>>,
    Data = <<"hello">>,  %% Only 5 bytes, need 10
    {more, N} = livery_h2_frame:decode(<<Header/binary, Data/binary>>),
    ?assertEqual(5, N).

%% ===================================================================
%% Error cases
%% ===================================================================

decode_window_update_zero_increment_test() ->
    %% WINDOW_UPDATE with 0 increment is a protocol error
    Frame = <<4:24, 8:8, 0:8, 0:1, 1:31, 0:1, 0:31>>,
    {error, protocol_error} = livery_h2_frame:decode(Frame).

decode_settings_wrong_stream_test() ->
    %% SETTINGS must be on stream 0
    Frame = <<0:24, 4:8, 0:8, 0:1, 1:31>>,
    {error, protocol_error} = livery_h2_frame:decode(Frame).

decode_ping_wrong_stream_test() ->
    %% PING must be on stream 0
    Frame = <<8:24, 6:8, 0:8, 0:1, 1:31, 1,2,3,4,5,6,7,8>>,
    {error, protocol_error} = livery_h2_frame:decode(Frame).

decode_settings_ack_with_payload_test() ->
    %% SETTINGS ACK must have empty payload
    Frame = <<6:24, 4:8, 1:8, 0:1, 0:31, 1:16, 4096:32>>,
    {error, frame_size_error} = livery_h2_frame:decode(Frame).

%% ===================================================================
%% Multiple frames test
%% ===================================================================

decode_multiple_frames_test() ->
    Frame1 = {data, 1, <<"first">>, false},
    Frame2 = {data, 1, <<"second">>, true},
    Encoded1 = iolist_to_binary(livery_h2_frame:encode(Frame1)),
    Encoded2 = iolist_to_binary(livery_h2_frame:encode(Frame2)),
    Combined = <<Encoded1/binary, Encoded2/binary>>,

    {ok, Decoded1, Rest1} = livery_h2_frame:decode(Combined),
    ?assertEqual(Frame1, Decoded1),

    {ok, Decoded2, Rest2} = livery_h2_frame:decode(Rest1),
    ?assertEqual(Frame2, Decoded2),
    ?assertEqual(<<>>, Rest2).

%% ===================================================================
%% Settings payload decode
%% ===================================================================

decode_settings_payload_test() ->
    Payload = <<1:16, 4096:32, 3:16, 100:32>>,
    {ok, Settings} = livery_h2_frame:decode_settings_payload(Payload),
    ?assertEqual(4096, maps:get(header_table_size, Settings)),
    ?assertEqual(100, maps:get(max_concurrent_streams, Settings)).

decode_settings_payload_unknown_test() ->
    %% Unknown settings should be ignored
    Payload = <<255:16, 999:32, 1:16, 2048:32>>,
    {ok, Settings} = livery_h2_frame:decode_settings_payload(Payload),
    ?assertEqual(2048, maps:get(header_table_size, Settings)),
    ?assertEqual(undefined, maps:get(unknown, Settings, undefined)).
