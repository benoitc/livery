%% @doc Unit tests for QPACK header compression (RFC 9204).
-module(livery_qpack_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% State creation
%% ===================================================================

init_test() ->
    State = livery_qpack:init(),
    ?assertMatch(State when is_tuple(State), State).

init_with_opts_test() ->
    State = livery_qpack:init(#{max_dynamic_size => 4096}),
    ?assertMatch(State when is_tuple(State), State).

%% ===================================================================
%% Basic encode/decode round-trips
%% ===================================================================

encode_decode_simple_header_test() ->
    State = livery_qpack:init(),
    Headers = [{<<"content-type">>, <<"text/html">>}],
    {Encoded, _State1} = livery_qpack:encode(Headers, State),
    {Result, _State2} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

encode_decode_multiple_headers_test() ->
    State = livery_qpack:init(),
    Headers = [
        {<<":status">>, <<"200">>},
        {<<"content-type">>, <<"application/json">>},
        {<<"content-length">>, <<"100">>}
    ],
    {Encoded, _State1} = livery_qpack:encode(Headers, State),
    {Result, _State2} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

%% ===================================================================
%% Static table tests
%% ===================================================================

encode_static_indexed_method_test() ->
    %% :method GET is index 17 in QPACK static table
    _State = livery_qpack:init(),
    Headers = [{<<":method">>, <<"GET">>}],
    Encoded = livery_qpack:encode(Headers),
    %% Decode should return same headers
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

encode_static_indexed_status_200_test() ->
    %% :status 200 is index 25 in QPACK static table
    _State = livery_qpack:init(),
    Headers = [{<<":status">>, <<"200">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

encode_static_indexed_path_root_test() ->
    %% :path / is index 1 in QPACK static table
    _State = livery_qpack:init(),
    Headers = [{<<":path">>, <<"/">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

encode_static_indexed_scheme_https_test() ->
    %% :scheme https is index 23 in QPACK static table
    _State = livery_qpack:init(),
    Headers = [{<<":scheme">>, <<"https">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Literal header with indexed name
%% ===================================================================

encode_literal_indexed_name_test() ->
    %% content-type has index 44 in static table, but with custom value
    _State = livery_qpack:init(),
    Headers = [{<<"content-type">>, <<"application/octet-stream">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Literal header with literal name
%% ===================================================================

encode_literal_new_name_test() ->
    _State = livery_qpack:init(),
    Headers = [{<<"x-custom-header">>, <<"custom-value">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% HTTP/3 typical request/response headers
%% ===================================================================

encode_decode_http3_request_test() ->
    State = livery_qpack:init(),
    Headers = [
        {<<":method">>, <<"GET">>},
        {<<":scheme">>, <<"https">>},
        {<<":path">>, <<"/">>},
        {<<":authority">>, <<"example.com">>}
    ],
    {Encoded, _} = livery_qpack:encode(Headers, State),
    {Result, _} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

encode_decode_http3_response_test() ->
    State = livery_qpack:init(),
    Headers = [
        {<<":status">>, <<"200">>},
        {<<"content-type">>, <<"text/html">>},
        {<<"content-length">>, <<"1234">>},
        {<<"server">>, <<"livery/1.0">>}
    ],
    {Encoded, _} = livery_qpack:encode(Headers, State),
    {Result, _} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

%% ===================================================================
%% Edge cases
%% ===================================================================

encode_decode_empty_value_test() ->
    State = livery_qpack:init(),
    Headers = [{<<"x-empty">>, <<>>}],
    {Encoded, _} = livery_qpack:encode(Headers, State),
    {Result, _} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

encode_decode_long_value_test() ->
    State = livery_qpack:init(),
    LongValue = binary:copy(<<"x">>, 500),
    Headers = [{<<"x-long">>, LongValue}],
    {Encoded, _} = livery_qpack:encode(Headers, State),
    {Result, _} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

encode_decode_long_name_test() ->
    State = livery_qpack:init(),
    LongName = binary:copy(<<"x">>, 100),
    Headers = [{LongName, <<"value">>}],
    {Encoded, _} = livery_qpack:encode(Headers, State),
    {Result, _} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

%% ===================================================================
%% Stateless API
%% ===================================================================

stateless_encode_decode_test() ->
    Headers = [{<<":status">>, <<"200">>}, {<<"server">>, <<"livery">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Multiple encode operations (state reuse)
%% ===================================================================

multiple_encode_test() ->
    State0 = livery_qpack:init(),

    %% First encode
    Headers1 = [{<<":status">>, <<"200">>}],
    {Encoded1, State1} = livery_qpack:encode(Headers1, State0),
    {Result1, _} = livery_qpack:decode(Encoded1, State0),
    ?assertEqual({ok, Headers1}, Result1),

    %% Second encode with same state
    Headers2 = [{<<":status">>, <<"404">>}],
    {Encoded2, _State2} = livery_qpack:encode(Headers2, State1),
    {Result2, _} = livery_qpack:decode(Encoded2, State0),
    ?assertEqual({ok, Headers2}, Result2).

%% ===================================================================
%% All status codes in static table
%% ===================================================================

status_codes_test_() ->
    StatusCodes = [<<"100">>, <<"103">>, <<"200">>, <<"204">>, <<"206">>,
                   <<"302">>, <<"304">>, <<"400">>, <<"403">>, <<"404">>,
                   <<"421">>, <<"425">>, <<"500">>, <<"503">>],
    [{"Status " ++ binary_to_list(Status),
      fun() ->
          Headers = [{<<":status">>, Status}],
          Encoded = livery_qpack:encode(Headers),
          {ok, Decoded} = livery_qpack:decode(Encoded),
          ?assertEqual(Headers, Decoded)
      end} || Status <- StatusCodes].

%% ===================================================================
%% All methods in static table
%% ===================================================================

methods_test_() ->
    Methods = [<<"CONNECT">>, <<"DELETE">>, <<"GET">>, <<"HEAD">>,
               <<"OPTIONS">>, <<"POST">>, <<"PUT">>],
    [{"Method " ++ binary_to_list(Method),
      fun() ->
          Headers = [{<<":method">>, Method}],
          Encoded = livery_qpack:encode(Headers),
          {ok, Decoded} = livery_qpack:decode(Encoded),
          ?assertEqual(Headers, Decoded)
      end} || Method <- Methods].

%% ===================================================================
%% Content types in static table
%% ===================================================================

content_types_test_() ->
    ContentTypes = [
        <<"application/dns-message">>,
        <<"application/javascript">>,
        <<"application/json">>,
        <<"application/x-www-form-urlencoded">>,
        <<"image/gif">>,
        <<"image/jpeg">>,
        <<"image/png">>,
        <<"text/css">>,
        <<"text/html; charset=utf-8">>,
        <<"text/plain">>,
        <<"text/plain;charset=utf-8">>
    ],
    [{"Content-Type: " ++ binary_to_list(CT),
      fun() ->
          Headers = [{<<"content-type">>, CT}],
          Encoded = livery_qpack:encode(Headers),
          {ok, Decoded} = livery_qpack:decode(Encoded),
          ?assertEqual(Headers, Decoded)
      end} || CT <- ContentTypes].

%% ===================================================================
%% Error cases
%% ===================================================================

decode_invalid_prefix_test() ->
    State = livery_qpack:init(),
    %% Single byte is not enough for prefix
    {{error, _}, _} = livery_qpack:decode(<<>>, State).

decode_empty_test() ->
    %% Empty input should fail
    {error, _} = livery_qpack:decode(<<>>).
