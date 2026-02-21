%% @doc Unit tests for WebSocket frame encoding/decoding.
-module(livery_ws_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% Handshake tests
%% ===================================================================

upgrade_key_test() ->
    %% RFC 6455 example
    Key = <<"dGhlIHNhbXBsZSBub25jZQ==">>,
    Expected = <<"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=">>,
    ?assertEqual(Expected, livery_ws:upgrade_key(Key)).

is_upgrade_request_valid_test() ->
    Headers = [
        {<<"upgrade">>, <<"websocket">>},
        {<<"connection">>, <<"Upgrade">>},
        {<<"sec-websocket-key">>, <<"dGhlIHNhbXBsZSBub25jZQ==">>},
        {<<"sec-websocket-version">>, <<"13">>}
    ],
    ?assert(livery_ws:is_upgrade_request(Headers)).

is_upgrade_request_missing_upgrade_test() ->
    Headers = [
        {<<"connection">>, <<"Upgrade">>},
        {<<"sec-websocket-key">>, <<"dGhlIHNhbXBsZSBub25jZQ==">>},
        {<<"sec-websocket-version">>, <<"13">>}
    ],
    ?assertNot(livery_ws:is_upgrade_request(Headers)).

is_upgrade_request_wrong_version_test() ->
    Headers = [
        {<<"upgrade">>, <<"websocket">>},
        {<<"connection">>, <<"Upgrade">>},
        {<<"sec-websocket-key">>, <<"dGhlIHNhbXBsZSBub25jZQ==">>},
        {<<"sec-websocket-version">>, <<"8">>}
    ],
    ?assertNot(livery_ws:is_upgrade_request(Headers)).

handshake_response_test() ->
    Key = <<"dGhlIHNhbXBsZSBub25jZQ==">>,
    Headers = livery_ws:handshake_response(Key),
    ?assert(lists:member({<<"upgrade">>, <<"websocket">>}, Headers)),
    ?assert(lists:member({<<"connection">>, <<"Upgrade">>}, Headers)),
    ?assert(lists:keymember(<<"sec-websocket-accept">>, 1, Headers)).

%% ===================================================================
%% Text frame encoding tests
%% ===================================================================

encode_text_small_test() ->
    Frame = livery_ws:encode_text(<<"Hello">>),
    %% FIN=1, RSV=000, Opcode=1 (text), MASK=0, Len=5
    ?assertEqual(<<16#81, 5, "Hello">>, Frame).

encode_text_medium_test() ->
    %% 126 bytes requires extended length
    Payload = binary:copy(<<"x">>, 200),
    Frame = livery_ws:encode_text(Payload),
    <<16#81, 126, 200:16, Rest/binary>> = Frame,
    ?assertEqual(Payload, Rest).

encode_text_large_test() ->
    %% 65536 bytes requires 8-byte extended length
    Payload = binary:copy(<<"x">>, 70000),
    Frame = livery_ws:encode_text(Payload),
    <<16#81, 127, 70000:64, Rest/binary>> = Frame,
    ?assertEqual(Payload, Rest).

%% ===================================================================
%% Binary frame encoding tests
%% ===================================================================

encode_binary_test() ->
    Frame = livery_ws:encode_binary(<<1, 2, 3, 4, 5>>),
    %% FIN=1, RSV=000, Opcode=2 (binary), MASK=0, Len=5
    ?assertEqual(<<16#82, 5, 1, 2, 3, 4, 5>>, Frame).

%% ===================================================================
%% Control frame encoding tests
%% ===================================================================

encode_ping_empty_test() ->
    Frame = livery_ws:encode_ping(),
    ?assertEqual(<<16#89, 0>>, Frame).

encode_ping_with_payload_test() ->
    Frame = livery_ws:encode_ping(<<"ping">>),
    ?assertEqual(<<16#89, 4, "ping">>, Frame).

encode_pong_test() ->
    Frame = livery_ws:encode_pong(<<"pong">>),
    ?assertEqual(<<16#8A, 4, "pong">>, Frame).

encode_close_empty_test() ->
    Frame = livery_ws:encode_close(),
    ?assertEqual(<<16#88, 0>>, Frame).

encode_close_with_code_test() ->
    Frame = livery_ws:encode_close(1000),
    ?assertEqual(<<16#88, 2, 1000:16>>, Frame).

encode_close_with_reason_test() ->
    Frame = livery_ws:encode_close(1001, <<"Going away">>),
    ?assertEqual(<<16#88, 12, 1001:16, "Going away">>, Frame).

%% ===================================================================
%% Frame decoding tests (masked, client -> server)
%% ===================================================================

decode_text_frame_test() ->
    MaskKey = <<16#37, 16#fa, 16#21, 16#3d>>,
    Payload = <<"Hello">>,
    Masked = livery_ws:mask(Payload, MaskKey),
    Frame = <<16#81, 16#85, MaskKey/binary, Masked/binary>>,
    {ok, text, Decoded, true, <<>>} = livery_ws:decode_frame(Frame),
    ?assertEqual(Payload, Decoded).

decode_binary_frame_test() ->
    MaskKey = <<1, 2, 3, 4>>,
    Payload = <<10, 20, 30, 40, 50>>,
    Masked = livery_ws:mask(Payload, MaskKey),
    Frame = <<16#82, 16#85, MaskKey/binary, Masked/binary>>,
    {ok, binary, Decoded, true, <<>>} = livery_ws:decode_frame(Frame),
    ?assertEqual(Payload, Decoded).

decode_ping_frame_test() ->
    MaskKey = <<1, 2, 3, 4>>,
    Payload = <<"ping">>,
    Masked = livery_ws:mask(Payload, MaskKey),
    Frame = <<16#89, 16#84, MaskKey/binary, Masked/binary>>,
    {ok, ping, Decoded, true, <<>>} = livery_ws:decode_frame(Frame),
    ?assertEqual(Payload, Decoded).

decode_pong_frame_test() ->
    MaskKey = <<1, 2, 3, 4>>,
    Payload = <<"pong">>,
    Masked = livery_ws:mask(Payload, MaskKey),
    Frame = <<16#8A, 16#84, MaskKey/binary, Masked/binary>>,
    {ok, pong, Decoded, true, <<>>} = livery_ws:decode_frame(Frame),
    ?assertEqual(Payload, Decoded).

decode_close_frame_test() ->
    MaskKey = <<1, 2, 3, 4>>,
    Payload = <<1000:16, "bye">>,
    Masked = livery_ws:mask(Payload, MaskKey),
    Frame = <<16#88, 16#85, MaskKey/binary, Masked/binary>>,
    {ok, close, Decoded, true, <<>>} = livery_ws:decode_frame(Frame),
    ?assertEqual(Payload, Decoded).

decode_fragmented_frame_test() ->
    %% First fragment (FIN=0)
    MaskKey = <<1, 2, 3, 4>>,
    Payload = <<"Hel">>,
    Masked = livery_ws:mask(Payload, MaskKey),
    Frame = <<16#01, 16#83, MaskKey/binary, Masked/binary>>,
    {ok, text, Decoded, false, <<>>} = livery_ws:decode_frame(Frame),
    ?assertEqual(Payload, Decoded).

decode_continuation_frame_test() ->
    %% Continuation fragment
    MaskKey = <<1, 2, 3, 4>>,
    Payload = <<"lo">>,
    Masked = livery_ws:mask(Payload, MaskKey),
    Frame = <<16#80, 16#82, MaskKey/binary, Masked/binary>>,
    {ok, continuation, Decoded, true, <<>>} = livery_ws:decode_frame(Frame),
    ?assertEqual(Payload, Decoded).

%% ===================================================================
%% Extended length decoding tests
%% ===================================================================

decode_medium_frame_test() ->
    MaskKey = <<1, 2, 3, 4>>,
    Payload = binary:copy(<<"x">>, 200),
    Masked = livery_ws:mask(Payload, MaskKey),
    Frame = <<16#82, 16#FE, 200:16, MaskKey/binary, Masked/binary>>,
    {ok, binary, Decoded, true, <<>>} = livery_ws:decode_frame(Frame),
    ?assertEqual(Payload, Decoded).

decode_large_frame_test() ->
    MaskKey = <<1, 2, 3, 4>>,
    Payload = binary:copy(<<"x">>, 70000),
    Masked = livery_ws:mask(Payload, MaskKey),
    Frame = <<16#82, 16#FF, 70000:64, MaskKey/binary, Masked/binary>>,
    {ok, binary, Decoded, true, <<>>} = livery_ws:decode_frame(Frame),
    ?assertEqual(Payload, Decoded).

%% ===================================================================
%% Partial frame tests
%% ===================================================================

decode_partial_header_test() ->
    {more, _} = livery_ws:decode_frame(<<16#81>>).

decode_partial_payload_test() ->
    MaskKey = <<1, 2, 3, 4>>,
    %% Frame claims 10 bytes but only 5 present
    Frame = <<16#82, 16#8A, MaskKey/binary, "hello">>,
    {more, N} = livery_ws:decode_frame(Frame),
    ?assertEqual(5, N).

%% ===================================================================
%% Multiple frames test
%% ===================================================================

decode_multiple_frames_test() ->
    MaskKey = <<1, 2, 3, 4>>,
    Payload1 = <<"first">>,
    Payload2 = <<"second">>,
    Masked1 = livery_ws:mask(Payload1, MaskKey),
    Masked2 = livery_ws:mask(Payload2, MaskKey),
    Frame1 = <<16#81, 16#85, MaskKey/binary, Masked1/binary>>,
    Frame2 = <<16#81, 16#86, MaskKey/binary, Masked2/binary>>,
    Combined = <<Frame1/binary, Frame2/binary>>,

    {ok, text, Decoded1, true, Rest} = livery_ws:decode_frame(Combined),
    ?assertEqual(Payload1, Decoded1),

    {ok, text, Decoded2, true, <<>>} = livery_ws:decode_frame(Rest),
    ?assertEqual(Payload2, Decoded2).

%% ===================================================================
%% Masking tests
%% ===================================================================

mask_unmask_roundtrip_test() ->
    MaskKey = <<16#37, 16#fa, 16#21, 16#3d>>,
    Data = <<"Hello, WebSocket!">>,
    Masked = livery_ws:mask(Data, MaskKey),
    Unmasked = livery_ws:unmask(Masked, MaskKey),
    ?assertEqual(Data, Unmasked).

mask_short_data_test() ->
    MaskKey = <<1, 2, 3, 4>>,
    %% Test various short lengths
    ?assertEqual(<<(1 bxor 1)>>, livery_ws:mask(<<1>>, MaskKey)),
    ?assertEqual(<<(1 bxor 1), (2 bxor 2)>>, livery_ws:mask(<<1, 2>>, MaskKey)),
    ?assertEqual(<<(1 bxor 1), (2 bxor 2), (3 bxor 3)>>, livery_ws:mask(<<1, 2, 3>>, MaskKey)).

mask_empty_test() ->
    MaskKey = <<1, 2, 3, 4>>,
    ?assertEqual(<<>>, livery_ws:mask(<<>>, MaskKey)).

%% ===================================================================
%% Error cases
%% ===================================================================

decode_invalid_frame_test() ->
    %% Too short to be a valid frame
    {more, _} = livery_ws:decode_frame(<<>>).
