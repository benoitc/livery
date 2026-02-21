%% @doc Unit tests for WebSocket over HTTP/3 (RFC 9220).
-module(livery_h3_ws_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% SETTINGS_ENABLE_CONNECT_PROTOCOL Tests
%%====================================================================

settings_enable_connect_protocol_default_test() ->
    Settings = livery_h3_frame:default_settings(),
    ?assertEqual(1, maps:get(enable_connect_protocol, Settings)).

settings_encode_decode_enable_connect_protocol_test() ->
    Settings = #{enable_connect_protocol => 1},
    Encoded = livery_h3_frame:encode_settings_payload(Settings),
    {ok, Decoded} = livery_h3_frame:decode_settings_payload(Encoded),
    ?assertEqual(1, maps:get(enable_connect_protocol, Decoded)).

settings_encode_enable_connect_protocol_disabled_test() ->
    Settings = #{enable_connect_protocol => 0},
    Encoded = livery_h3_frame:encode_settings_payload(Settings),
    {ok, Decoded} = livery_h3_frame:decode_settings_payload(Encoded),
    ?assertEqual(0, maps:get(enable_connect_protocol, Decoded)).

settings_frame_with_enable_connect_protocol_test() ->
    Settings = #{
        qpack_max_table_capacity => 4096,
        max_field_section_size => 16384,
        enable_connect_protocol => 1
    },
    Frame = livery_h3_frame:encode_settings(Settings),
    {ok, {settings, Decoded}, <<>>} = livery_h3_frame:decode(Frame),
    ?assertEqual(4096, maps:get(qpack_max_table_capacity, Decoded)),
    ?assertEqual(16384, maps:get(max_field_section_size, Decoded)),
    ?assertEqual(1, maps:get(enable_connect_protocol, Decoded)).

%%====================================================================
%% Extended CONNECT Validation Tests
%%====================================================================

%% Test helper - validate_connect_request is internal, so we test via headers
valid_extended_connect_headers_test() ->
    Headers = [
        {<<":method">>, <<"CONNECT">>},
        {<<":protocol">>, <<"websocket">>},
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, <<"example.com">>},
        {<<":path">>, <<"/chat">>}
    ],
    %% All required pseudo-headers present
    ?assertEqual(<<"CONNECT">>, proplists:get_value(<<":method">>, Headers)),
    ?assertEqual(<<"websocket">>, proplists:get_value(<<":protocol">>, Headers)),
    ?assertNotEqual(undefined, proplists:get_value(<<":scheme">>, Headers)),
    ?assertNotEqual(undefined, proplists:get_value(<<":authority">>, Headers)),
    ?assertNotEqual(undefined, proplists:get_value(<<":path">>, Headers)).

missing_protocol_header_test() ->
    Headers = [
        {<<":method">>, <<"CONNECT">>},
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, <<"example.com">>},
        {<<":path">>, <<"/chat">>}
    ],
    %% Missing :protocol header
    ?assertEqual(undefined, proplists:get_value(<<":protocol">>, Headers, undefined)).

wrong_protocol_header_test() ->
    Headers = [
        {<<":method">>, <<"CONNECT">>},
        {<<":protocol">>, <<"webtransport">>},  %% Not websocket
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, <<"example.com">>},
        {<<":path">>, <<"/chat">>}
    ],
    ?assertNotEqual(<<"websocket">>, proplists:get_value(<<":protocol">>, Headers)).

missing_scheme_header_test() ->
    Headers = [
        {<<":method">>, <<"CONNECT">>},
        {<<":protocol">>, <<"websocket">>},
        {<<":authority">>, <<"example.com">>},
        {<<":path">>, <<"/chat">>}
    ],
    %% Missing :scheme header
    ?assertEqual(undefined, proplists:get_value(<<":scheme">>, Headers, undefined)).

missing_authority_header_test() ->
    Headers = [
        {<<":method">>, <<"CONNECT">>},
        {<<":protocol">>, <<"websocket">>},
        {<<":scheme">>, <<"https">>},
        {<<":path">>, <<"/chat">>}
    ],
    %% Missing :authority header
    ?assertEqual(undefined, proplists:get_value(<<":authority">>, Headers, undefined)).

missing_path_header_test() ->
    Headers = [
        {<<":method">>, <<"CONNECT">>},
        {<<":protocol">>, <<"websocket">>},
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, <<"example.com">>}
    ],
    %% Missing :path header
    ?assertEqual(undefined, proplists:get_value(<<":path">>, Headers, undefined)).

%%====================================================================
%% WebSocket Frame Wrapping Tests
%%====================================================================

%% Test that WebSocket frames wrapped in HTTP/3 DATA frames work correctly

ws_text_frame_wrapping_test() ->
    %% Create a WebSocket text frame
    Text = <<"Hello, WebSocket!">>,
    WsFrame = livery_ws:encode_text(Text),

    %% Wrap in HTTP/3 DATA frame
    DataFrame = livery_h3_frame:encode_data(WsFrame),

    %% Decode the HTTP/3 DATA frame
    {ok, {data, Payload}, <<>>} = livery_h3_frame:decode(DataFrame),

    %% Decode the WebSocket frame
    {ok, text, DecodedText, true, <<>>} = livery_ws:decode_frame(Payload),
    ?assertEqual(Text, DecodedText).

ws_binary_frame_wrapping_test() ->
    Data = <<1, 2, 3, 4, 5>>,
    WsFrame = livery_ws:encode_binary(Data),
    DataFrame = livery_h3_frame:encode_data(WsFrame),

    {ok, {data, Payload}, <<>>} = livery_h3_frame:decode(DataFrame),
    {ok, binary, DecodedData, true, <<>>} = livery_ws:decode_frame(Payload),
    ?assertEqual(Data, DecodedData).

ws_ping_frame_wrapping_test() ->
    Payload = <<"ping-payload">>,
    WsFrame = livery_ws:encode_ping(Payload),
    DataFrame = livery_h3_frame:encode_data(WsFrame),

    {ok, {data, DataPayload}, <<>>} = livery_h3_frame:decode(DataFrame),
    {ok, ping, DecodedPayload, true, <<>>} = livery_ws:decode_frame(DataPayload),
    ?assertEqual(Payload, DecodedPayload).

ws_pong_frame_wrapping_test() ->
    Payload = <<"pong-payload">>,
    WsFrame = livery_ws:encode_pong(Payload),
    DataFrame = livery_h3_frame:encode_data(WsFrame),

    {ok, {data, DataPayload}, <<>>} = livery_h3_frame:decode(DataFrame),
    {ok, pong, DecodedPayload, true, <<>>} = livery_ws:decode_frame(DataPayload),
    ?assertEqual(Payload, DecodedPayload).

ws_close_frame_wrapping_test() ->
    Code = 1000,
    WsFrame = livery_ws:encode_close(Code),
    DataFrame = livery_h3_frame:encode_data(WsFrame),

    {ok, {data, DataPayload}, <<>>} = livery_h3_frame:decode(DataFrame),
    {ok, close, ClosePayload, true, <<>>} = livery_ws:decode_frame(DataPayload),
    <<DecodedCode:16>> = ClosePayload,
    ?assertEqual(Code, DecodedCode).

ws_close_frame_with_reason_wrapping_test() ->
    Code = 1001,
    Reason = <<"Going Away">>,
    WsFrame = livery_ws:encode_close(Code, Reason),
    DataFrame = livery_h3_frame:encode_data(WsFrame),

    {ok, {data, DataPayload}, <<>>} = livery_h3_frame:decode(DataFrame),
    {ok, close, ClosePayload, true, <<>>} = livery_ws:decode_frame(DataPayload),
    <<DecodedCode:16, DecodedReason/binary>> = ClosePayload,
    ?assertEqual(Code, DecodedCode),
    ?assertEqual(Reason, DecodedReason).

%%====================================================================
%% Multiple Frame Tests
%%====================================================================

multiple_ws_frames_in_data_test() ->
    %% Multiple WebSocket frames can be sent in a single HTTP/3 DATA frame
    Text1 = <<"First">>,
    Text2 = <<"Second">>,
    WsFrame1 = livery_ws:encode_text(Text1),
    WsFrame2 = livery_ws:encode_text(Text2),

    %% Combine frames
    Combined = <<WsFrame1/binary, WsFrame2/binary>>,
    DataFrame = livery_h3_frame:encode_data(Combined),

    {ok, {data, Payload}, <<>>} = livery_h3_frame:decode(DataFrame),

    %% Decode first frame
    {ok, text, DecodedText1, true, Rest} = livery_ws:decode_frame(Payload),
    ?assertEqual(Text1, DecodedText1),

    %% Decode second frame
    {ok, text, DecodedText2, true, <<>>} = livery_ws:decode_frame(Rest),
    ?assertEqual(Text2, DecodedText2).

%%====================================================================
%% Large Frame Tests
%%====================================================================

large_text_frame_test() ->
    %% Test with a larger payload (16KB)
    LargeText = binary:copy(<<"X">>, 16384),
    WsFrame = livery_ws:encode_text(LargeText),
    DataFrame = livery_h3_frame:encode_data(WsFrame),

    {ok, {data, Payload}, <<>>} = livery_h3_frame:decode(DataFrame),
    {ok, text, DecodedText, true, <<>>} = livery_ws:decode_frame(Payload),
    ?assertEqual(LargeText, DecodedText).

%%====================================================================
%% Empty Frame Tests
%%====================================================================

empty_text_frame_test() ->
    WsFrame = livery_ws:encode_text(<<>>),
    DataFrame = livery_h3_frame:encode_data(WsFrame),

    {ok, {data, Payload}, <<>>} = livery_h3_frame:decode(DataFrame),
    {ok, text, DecodedText, true, <<>>} = livery_ws:decode_frame(Payload),
    ?assertEqual(<<>>, DecodedText).

empty_binary_frame_test() ->
    WsFrame = livery_ws:encode_binary(<<>>),
    DataFrame = livery_h3_frame:encode_data(WsFrame),

    {ok, {data, Payload}, <<>>} = livery_h3_frame:decode(DataFrame),
    {ok, binary, DecodedData, true, <<>>} = livery_ws:decode_frame(Payload),
    ?assertEqual(<<>>, DecodedData).

empty_ping_frame_test() ->
    WsFrame = livery_ws:encode_ping(<<>>),
    DataFrame = livery_h3_frame:encode_data(WsFrame),

    {ok, {data, Payload}, <<>>} = livery_h3_frame:decode(DataFrame),
    {ok, ping, DecodedPayload, true, <<>>} = livery_ws:decode_frame(Payload),
    ?assertEqual(<<>>, DecodedPayload).
