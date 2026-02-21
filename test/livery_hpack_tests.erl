%% @doc Unit tests for HPACK header compression (RFC 7541).
-module(livery_hpack_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% Encoder/Decoder creation
%% ===================================================================

encoder_new_test() ->
    Encoder = livery_hpack:encoder_new(),
    ?assertMatch(Encoder when is_tuple(Encoder), Encoder).

encoder_new_with_size_test() ->
    Encoder = livery_hpack:encoder_new(8192),
    ?assertMatch(Encoder when is_tuple(Encoder), Encoder).

decoder_new_test() ->
    Decoder = livery_hpack:decoder_new(),
    ?assertMatch(Decoder when is_tuple(Decoder), Decoder).

decoder_new_with_size_test() ->
    Decoder = livery_hpack:decoder_new(8192),
    ?assertMatch(Decoder when is_tuple(Decoder), Decoder).

%% ===================================================================
%% Basic encode/decode round-trips
%% ===================================================================

encode_decode_simple_header_test() ->
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    Headers = [{<<"content-type">>, <<"text/html">>}],
    {Encoded, _Encoder1} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    {ok, Decoded, _Decoder1} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

encode_decode_multiple_headers_test() ->
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    Headers = [
        {<<":status">>, <<"200">>},
        {<<"content-type">>, <<"application/json">>},
        {<<"content-length">>, <<"100">>}
    ],
    {Encoded, _Encoder1} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    {ok, Decoded, _Decoder1} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Static table tests
%% ===================================================================

encode_static_indexed_test() ->
    %% :method GET is index 2 in static table
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    Headers = [{<<":method">>, <<"GET">>}],
    {Encoded, _} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    %% Should be a single byte: 0x82 (indexed header field, index 2)
    ?assertEqual(<<16#82>>, EncodedBin),
    {ok, Decoded, _} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

encode_static_status_200_test() ->
    %% :status 200 is index 8 in static table
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    Headers = [{<<":status">>, <<"200">>}],
    {Encoded, _} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    %% Should be 0x88 (indexed header field, index 8)
    ?assertEqual(<<16#88>>, EncodedBin),
    {ok, Decoded, _} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

encode_static_path_root_test() ->
    %% :path / is index 4 in static table
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    Headers = [{<<":path">>, <<"/">>}],
    {Encoded, _} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    ?assertEqual(<<16#84>>, EncodedBin),
    {ok, Decoded, _} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

encode_static_scheme_https_test() ->
    %% :scheme https is index 7 in static table
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    Headers = [{<<":scheme">>, <<"https">>}],
    {Encoded, _} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    ?assertEqual(<<16#87>>, EncodedBin),
    {ok, Decoded, _} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Literal header with indexed name
%% ===================================================================

encode_literal_indexed_name_test() ->
    %% content-type has index 31, but with custom value
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    Headers = [{<<"content-type">>, <<"application/json">>}],
    {Encoded, _} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    {ok, Decoded, _} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Literal header with new name
%% ===================================================================

encode_literal_new_name_test() ->
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    Headers = [{<<"x-custom-header">>, <<"custom-value">>}],
    {Encoded, _} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    {ok, Decoded, _} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Dynamic table tests
%% ===================================================================

dynamic_table_reuse_test() ->
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),

    %% First encode adds to dynamic table
    Headers1 = [{<<"x-custom">>, <<"value1">>}],
    {Encoded1, Encoder1} = livery_hpack:encode(Headers1, Encoder),
    Encoded1Bin = iolist_to_binary(Encoded1),
    {ok, _, Decoder1} = livery_hpack:decode(Encoded1Bin, Decoder),

    %% Second encode with same header should reuse dynamic table
    %% and produce smaller encoding
    Headers2 = [{<<"x-custom">>, <<"value1">>}],
    {Encoded2, _Encoder2} = livery_hpack:encode(Headers2, Encoder1),
    Encoded2Bin = iolist_to_binary(Encoded2),
    {ok, Decoded2, _Decoder2} = livery_hpack:decode(Encoded2Bin, Decoder1),

    ?assertEqual(Headers2, Decoded2),
    %% Second encoding should be smaller (indexed reference)
    ?assert(byte_size(Encoded2Bin) =< byte_size(Encoded1Bin)).

%% ===================================================================
%% Integer encoding tests (RFC 7541 Section 5.1)
%% ===================================================================

decode_integer_small_test() ->
    %% Small integer that fits in prefix
    %% Index 2 with 7-bit prefix: 0x82 = 10000010
    Decoder = livery_hpack:decoder_new(),
    {ok, [{<<":method">>, <<"GET">>}], _} = livery_hpack:decode(<<16#82>>, Decoder).

decode_integer_multi_byte_test() ->
    %% Large integer that doesn't fit in prefix
    %% Encoder encodes index > 127 with continuation bytes
    Encoder = livery_hpack:encoder_new(16384),
    Decoder = livery_hpack:decoder_new(16384),

    %% Add many headers to push dynamic table index high
    Headers = [{list_to_binary("x-header-" ++ integer_to_list(N)), <<"value">>}
               || N <- lists:seq(1, 10)],
    {Encoded, _} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    {ok, Decoded, _} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% String encoding tests (RFC 7541 Section 5.2)
%% ===================================================================

encode_decode_empty_value_test() ->
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    Headers = [{<<"x-empty">>, <<>>}],
    {Encoded, _} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    {ok, Decoded, _} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

encode_decode_long_value_test() ->
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    LongValue = binary:copy(<<"x">>, 1000),
    Headers = [{<<"x-long">>, LongValue}],
    {Encoded, _} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    {ok, Decoded, _} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Table size update tests
%% ===================================================================

encoder_set_max_size_test() ->
    Encoder = livery_hpack:encoder_new(4096),
    Encoder1 = livery_hpack:encoder_set_max_size(2048, Encoder),
    ?assertMatch(Encoder1 when is_tuple(Encoder1), Encoder1).

decoder_set_max_size_test() ->
    Decoder = livery_hpack:decoder_new(4096),
    Decoder1 = livery_hpack:decoder_set_max_size(2048, Decoder),
    ?assertMatch(Decoder1 when is_tuple(Decoder1), Decoder1).

%% ===================================================================
%% Error cases
%% ===================================================================

decode_invalid_index_test() ->
    Decoder = livery_hpack:decoder_new(),
    %% Index 0 is invalid for indexed header
    {error, invalid_index} = livery_hpack:decode(<<16#80>>, Decoder).

decode_incomplete_integer_test() ->
    Decoder = livery_hpack:decoder_new(),
    %% 7-bit prefix all 1s indicates continuation but nothing follows
    {error, incomplete_integer} = livery_hpack:decode(<<16#FF>>, Decoder).

%% ===================================================================
%% RFC 7541 Examples (Appendix C)
%% ===================================================================

%% C.2.1 Literal Header Field with Indexing
rfc_example_c2_1_test() ->
    Decoder = livery_hpack:decoder_new(),
    %% custom-key: custom-header
    %% 40 0a 6375 7374 6f6d 2d6b 6579 0d 6375 7374 6f6d 2d68 6561 6465 72
    Input = <<16#40, 16#0a, "custom-key", 16#0d, "custom-header">>,
    {ok, Decoded, _} = livery_hpack:decode(Input, Decoder),
    ?assertEqual([{<<"custom-key">>, <<"custom-header">>}], Decoded).

%% C.2.2 Literal Header Field without Indexing
rfc_example_c2_2_test() ->
    Decoder = livery_hpack:decoder_new(),
    %% :path: /sample/path
    %% 04 0c 2f73 616d 706c 652f 7061 7468
    Input = <<16#04, 16#0c, "/sample/path">>,
    {ok, Decoded, _} = livery_hpack:decode(Input, Decoder),
    ?assertEqual([{<<":path">>, <<"/sample/path">>}], Decoded).

%% C.2.3 Literal Header Field Never Indexed
rfc_example_c2_3_test() ->
    Decoder = livery_hpack:decoder_new(),
    %% password: secret
    %% 10 08 7061 7373 776f 7264 06 7365 6372 6574
    Input = <<16#10, 16#08, "password", 16#06, "secret">>,
    {ok, Decoded, _} = livery_hpack:decode(Input, Decoder),
    ?assertEqual([{<<"password">>, <<"secret">>}], Decoded).

%% C.2.4 Indexed Header Field
rfc_example_c2_4_test() ->
    Decoder = livery_hpack:decoder_new(),
    %% :method: GET (index 2)
    %% 82
    Input = <<16#82>>,
    {ok, Decoded, _} = livery_hpack:decode(Input, Decoder),
    ?assertEqual([{<<":method">>, <<"GET">>}], Decoded).

%% ===================================================================
%% HTTP/2 typical request/response headers
%% ===================================================================

encode_decode_http2_request_test() ->
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    Headers = [
        {<<":method">>, <<"GET">>},
        {<<":scheme">>, <<"https">>},
        {<<":path">>, <<"/">>},
        {<<":authority">>, <<"example.com">>}
    ],
    {Encoded, _} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    {ok, Decoded, _} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

encode_decode_http2_response_test() ->
    Encoder = livery_hpack:encoder_new(),
    Decoder = livery_hpack:decoder_new(),
    Headers = [
        {<<":status">>, <<"200">>},
        {<<"content-type">>, <<"text/html">>},
        {<<"content-length">>, <<"1234">>},
        {<<"server">>, <<"livery/1.0">>}
    ],
    {Encoded, _} = livery_hpack:encode(Headers, Encoder),
    EncodedBin = iolist_to_binary(Encoded),
    {ok, Decoded, _} = livery_hpack:decode(EncodedBin, Decoder),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Connection reuse test (multiple requests)
%% ===================================================================

multiple_requests_test() ->
    Encoder0 = livery_hpack:encoder_new(),
    Decoder0 = livery_hpack:decoder_new(),

    %% First request
    Headers1 = [
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>},
        {<<"host">>, <<"example.com">>}
    ],
    {Encoded1, Encoder1} = livery_hpack:encode(Headers1, Encoder0),
    {ok, Decoded1, Decoder1} = livery_hpack:decode(iolist_to_binary(Encoded1), Decoder0),
    ?assertEqual(Headers1, Decoded1),

    %% Second request - should benefit from dynamic table
    Headers2 = [
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/api">>},
        {<<"host">>, <<"example.com">>}
    ],
    {Encoded2, Encoder2} = livery_hpack:encode(Headers2, Encoder1),
    {ok, Decoded2, Decoder2} = livery_hpack:decode(iolist_to_binary(Encoded2), Decoder1),
    ?assertEqual(Headers2, Decoded2),

    %% Third request
    Headers3 = [
        {<<":method">>, <<"POST">>},
        {<<":path">>, <<"/api/data">>},
        {<<"host">>, <<"example.com">>},
        {<<"content-type">>, <<"application/json">>}
    ],
    {Encoded3, _Encoder3} = livery_hpack:encode(Headers3, Encoder2),
    {ok, Decoded3, _Decoder3} = livery_hpack:decode(iolist_to_binary(Encoded3), Decoder2),
    ?assertEqual(Headers3, Decoded3).
