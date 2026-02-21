%% @doc Unit tests for HTTP/1.x parser.
-module(livery_h1_parse_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test fixtures

simple_get_request() ->
    <<"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n">>.

post_request_with_body() ->
    <<"POST /api HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\ntest">>.

request_with_multiple_headers() ->
    <<"GET /path HTTP/1.1\r\n",
      "Host: example.com\r\n",
      "Accept: text/html\r\n",
      "User-Agent: test\r\n\r\n">>.

%% Basic parsing tests

parse_simple_get_test() ->
    {ok, Method, Path, Qs, Version, Headers, Rest} =
        livery_h1_parse:parse_request(simple_get_request()),
    ?assertEqual(<<"GET">>, Method),
    ?assertEqual(<<"/">>, Path),
    ?assertEqual(<<>>, Qs),
    ?assertEqual({1, 1}, Version),
    ?assertEqual([{<<"host">>, <<"localhost">>}], Headers),
    ?assertEqual(<<>>, Rest).

parse_post_with_body_test() ->
    {ok, Method, Path, Qs, Version, Headers, Rest} =
        livery_h1_parse:parse_request(post_request_with_body()),
    ?assertEqual(<<"POST">>, Method),
    ?assertEqual(<<"/api">>, Path),
    ?assertEqual(<<>>, Qs),
    ?assertEqual({1, 1}, Version),
    ?assertEqual([{<<"host">>, <<"localhost">>},
                  {<<"content-length">>, <<"4">>}], Headers),
    ?assertEqual(<<"test">>, Rest).

parse_multiple_headers_test() ->
    {ok, Method, Path, _Qs, _Version, Headers, _Rest} =
        livery_h1_parse:parse_request(request_with_multiple_headers()),
    ?assertEqual(<<"GET">>, Method),
    ?assertEqual(<<"/path">>, Path),
    ?assertEqual(3, length(Headers)),
    ?assertEqual(<<"example.com">>, proplists:get_value(<<"host">>, Headers)),
    ?assertEqual(<<"text/html">>, proplists:get_value(<<"accept">>, Headers)),
    ?assertEqual(<<"test">>, proplists:get_value(<<"user-agent">>, Headers)).

parse_query_string_test() ->
    Req = <<"GET /search?q=test&page=1 HTTP/1.1\r\nHost: localhost\r\n\r\n">>,
    {ok, _Method, Path, Qs, _Version, _Headers, _Rest} =
        livery_h1_parse:parse_request(Req),
    ?assertEqual(<<"/search">>, Path),
    ?assertEqual(<<"q=test&page=1">>, Qs).

parse_http10_test() ->
    Req = <<"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n">>,
    {ok, _Method, _Path, _Qs, Version, _Headers, _Rest} =
        livery_h1_parse:parse_request(Req),
    ?assertEqual({1, 0}, Version).

%% HTTP methods

parse_all_methods_test_() ->
    Methods = [<<"GET">>, <<"POST">>, <<"PUT">>, <<"DELETE">>,
               <<"HEAD">>, <<"OPTIONS">>, <<"PATCH">>],
    [?_test(begin
        Req = <<M/binary, " / HTTP/1.1\r\nHost: localhost\r\n\r\n">>,
        {ok, Method, _, _, _, _, _} = livery_h1_parse:parse_request(Req),
        ?assertEqual(M, Method)
    end) || M <- Methods].

%% Case insensitivity

lowercase_method_test() ->
    Req = <<"get / HTTP/1.1\r\nHost: localhost\r\n\r\n">>,
    {ok, Method, _, _, _, _, _} = livery_h1_parse:parse_request(Req),
    ?assertEqual(<<"GET">>, Method).

header_name_case_insensitive_test() ->
    Req = <<"GET / HTTP/1.1\r\nHoSt: localhost\r\nContent-TYPE: text/plain\r\n\r\n">>,
    {ok, _, _, _, _, Headers, _} = livery_h1_parse:parse_request(Req),
    ?assertEqual(<<"localhost">>, proplists:get_value(<<"host">>, Headers)),
    ?assertEqual(<<"text/plain">>, proplists:get_value(<<"content-type">>, Headers)).

%% Partial data (more needed)

partial_method_test() ->
    {more, _} = livery_h1_parse:parse_request(<<"GE">>).

partial_uri_test() ->
    {more, _} = livery_h1_parse:parse_request(<<"GET /foo">>).

partial_version_test() ->
    {more, _} = livery_h1_parse:parse_request(<<"GET / HTTP/1">>).

partial_headers_test() ->
    {more, _} = livery_h1_parse:parse_request(<<"GET / HTTP/1.1\r\nHost: local">>).

%% Edge cases

empty_path_test() ->
    %% Minimum valid request
    Req = <<"GET / HTTP/1.1\r\n\r\n">>,
    {ok, _, Path, _, _, _, _} = livery_h1_parse:parse_request(Req),
    ?assertEqual(<<"/">>, Path).

header_with_whitespace_test() ->
    Req = <<"GET / HTTP/1.1\r\nHost:   localhost  \r\n\r\n">>,
    {ok, _, _, _, _, Headers, _} = livery_h1_parse:parse_request(Req),
    ?assertEqual(<<"localhost">>, proplists:get_value(<<"host">>, Headers)).

pipelined_requests_test() ->
    Req = <<"GET /first HTTP/1.1\r\nHost: localhost\r\n\r\nGET /second HTTP/1.1\r\nHost: localhost\r\n\r\n">>,
    {ok, _, Path1, _, _, _, Rest1} = livery_h1_parse:parse_request(Req),
    ?assertEqual(<<"/first">>, Path1),
    {ok, _, Path2, _, _, _, _} = livery_h1_parse:parse_request(Rest1),
    ?assertEqual(<<"/second">>, Path2).

%% Error cases

invalid_method_char_test() ->
    Req = <<"GET1 / HTTP/1.1\r\n\r\n">>,
    {error, invalid_method} = livery_h1_parse:parse_request(Req).

method_too_long_test() ->
    LongMethod = binary:copy(<<"A">>, 20),
    Req = <<LongMethod/binary, " / HTTP/1.1\r\n\r\n">>,
    {error, method_too_long} = livery_h1_parse:parse_request(Req).

uri_too_long_test() ->
    LongUri = binary:copy(<<"a">>, 10000),
    Req = <<"GET /", LongUri/binary, " HTTP/1.1\r\n\r\n">>,
    {error, uri_too_long} = livery_h1_parse:parse_request(Req).

invalid_uri_char_test() ->
    Req = <<"GET /path\x00 HTTP/1.1\r\n\r\n">>,
    {error, invalid_uri} = livery_h1_parse:parse_request(Req).

invalid_version_test() ->
    Req = <<"GET / HTTP/2.0\r\n\r\n">>,
    %% HTTP/2.0 is valid version string, but we accept any X.Y
    {ok, _, _, _, Version, _, _} = livery_h1_parse:parse_request(Req),
    ?assertEqual({2, 0}, Version).

invalid_version_format_test() ->
    Req = <<"GET / HTTZ/1.1\r\n\r\n">>,
    {error, invalid_version} = livery_h1_parse:parse_request(Req).

header_name_too_long_test() ->
    LongName = binary:copy(<<"X">>, 300),
    Req = <<"GET / HTTP/1.1\r\n", LongName/binary, ": value\r\n\r\n">>,
    {error, header_name_too_long} = livery_h1_parse:parse_request(Req).

header_value_too_long_test() ->
    LongValue = binary:copy(<<"a">>, 10000),
    Req = <<"GET / HTTP/1.1\r\nX-Header: ", LongValue/binary, "\r\n\r\n">>,
    {error, header_value_too_long} = livery_h1_parse:parse_request(Req).

too_many_headers_test() ->
    Headers = iolist_to_binary([
        [<<"X-Header-">>, integer_to_binary(N), <<": value\r\n">>]
        || N <- lists:seq(1, 150)
    ]),
    Req = <<"GET / HTTP/1.1\r\n", Headers/binary, "\r\n">>,
    {error, too_many_headers} = livery_h1_parse:parse_request(Req).

%% Custom limits

custom_limits_test() ->
    Limits = #{max_method_size => 4},
    Req = <<"DELETE / HTTP/1.1\r\n\r\n">>,
    {error, method_too_long} = livery_h1_parse:parse_request(Req, Limits).

custom_uri_limit_test() ->
    Limits = #{max_uri_size => 10},
    Req = <<"GET /very/long/path HTTP/1.1\r\n\r\n">>,
    {error, uri_too_long} = livery_h1_parse:parse_request(Req, Limits).

%% Chunk parsing tests

parse_simple_chunk_test() ->
    Data = <<"5\r\nhello\r\n">>,
    {ok, Chunk, Rest} = livery_h1_parse:parse_chunk(Data),
    ?assertEqual(<<"hello">>, Chunk),
    ?assertEqual(<<>>, Rest).

parse_hex_chunk_size_test() ->
    Data = <<"a\r\n0123456789\r\n">>,
    {ok, Chunk, Rest} = livery_h1_parse:parse_chunk(Data),
    ?assertEqual(<<"0123456789">>, Chunk),
    ?assertEqual(<<>>, Rest).

parse_uppercase_hex_chunk_test() ->
    Data = <<"A\r\n0123456789\r\n">>,
    {ok, Chunk, Rest} = livery_h1_parse:parse_chunk(Data),
    ?assertEqual(<<"0123456789">>, Chunk),
    ?assertEqual(<<>>, Rest).

parse_large_hex_chunk_test() ->
    Data = <<"1F\r\n", (binary:copy(<<"x">>, 31))/binary, "\r\n">>,
    {ok, Chunk, Rest} = livery_h1_parse:parse_chunk(Data),
    ?assertEqual(31, byte_size(Chunk)),
    ?assertEqual(<<>>, Rest).

parse_final_chunk_test() ->
    Data = <<"0\r\n\r\n">>,
    {done, Rest} = livery_h1_parse:parse_chunk(Data),
    ?assertEqual(<<"\r\n">>, Rest).

parse_chunk_with_extension_test() ->
    Data = <<"5;ext=value\r\nhello\r\n">>,
    {ok, Chunk, Rest} = livery_h1_parse:parse_chunk(Data),
    ?assertEqual(<<"hello">>, Chunk),
    ?assertEqual(<<>>, Rest).

parse_chunk_partial_size_test() ->
    {more, _} = livery_h1_parse:parse_chunk(<<"1">>).

parse_chunk_partial_data_test() ->
    {more, _} = livery_h1_parse:parse_chunk(<<"5\r\nhel">>).

parse_chunk_partial_crlf_test() ->
    {more, _} = livery_h1_parse:parse_chunk(<<"5\r\nhello\r">>).

parse_chunk_invalid_size_test() ->
    {error, invalid_chunk_size} = livery_h1_parse:parse_chunk(<<"xyz\r\n">>).

parse_chunk_multiple_test() ->
    Data = <<"5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n">>,
    {ok, Chunk1, Rest1} = livery_h1_parse:parse_chunk(Data),
    ?assertEqual(<<"hello">>, Chunk1),
    {ok, Chunk2, Rest2} = livery_h1_parse:parse_chunk(Rest1),
    ?assertEqual(<<"world">>, Chunk2),
    {done, Rest3} = livery_h1_parse:parse_chunk(Rest2),
    ?assertEqual(<<"\r\n">>, Rest3).

%% Trailer parsing tests

parse_empty_trailers_test() ->
    Data = <<"\r\n">>,
    {ok, Trailers, Rest} = livery_h1_parse:parse_trailers(Data),
    ?assertEqual([], Trailers),
    ?assertEqual(<<>>, Rest).

parse_single_trailer_test() ->
    Data = <<"X-Checksum: abc123\r\n\r\n">>,
    {ok, Trailers, Rest} = livery_h1_parse:parse_trailers(Data),
    ?assertEqual([{<<"x-checksum">>, <<"abc123">>}], Trailers),
    ?assertEqual(<<>>, Rest).

parse_multiple_trailers_test() ->
    Data = <<"X-Checksum: abc123\r\nX-Length: 100\r\n\r\n">>,
    {ok, Trailers, Rest} = livery_h1_parse:parse_trailers(Data),
    ?assertEqual(2, length(Trailers)),
    ?assertEqual(<<"abc123">>, proplists:get_value(<<"x-checksum">>, Trailers)),
    ?assertEqual(<<"100">>, proplists:get_value(<<"x-length">>, Trailers)),
    ?assertEqual(<<>>, Rest).

parse_trailers_partial_test() ->
    {more, _} = livery_h1_parse:parse_trailers(<<"X-Check">>).

%% Chunked response encoding tests

encode_chunk_test() ->
    Encoded = iolist_to_binary(livery_resp:encode_chunk(<<"hello">>)),
    ?assertEqual(<<"5\r\nhello\r\n">>, Encoded).

encode_empty_chunk_test() ->
    Encoded = iolist_to_binary(livery_resp:encode_chunk(<<>>)),
    ?assertEqual(<<"0\r\n\r\n">>, Encoded).

encode_last_chunk_test() ->
    Encoded = livery_resp:encode_last_chunk(),
    ?assertEqual(<<"0\r\n\r\n">>, Encoded).

encode_last_chunk_with_trailers_test() ->
    Encoded = iolist_to_binary(livery_resp:encode_last_chunk([{<<"x-checksum">>, <<"abc">>}])),
    ?assertEqual(<<"0\r\nx-checksum: abc\r\n\r\n">>, Encoded).

build_chunked_start_test() ->
    Encoded = iolist_to_binary(livery_resp:build_chunked_start(200, [{<<"content-type">>, <<"text/plain">>}], {1, 1})),
    ?assertMatch({match, _}, re:run(Encoded, <<"HTTP/1.1 200 OK">>)),
    ?assertMatch({match, _}, re:run(Encoded, <<"transfer-encoding: chunked">>)),
    ?assertMatch({match, _}, re:run(Encoded, <<"content-type: text/plain">>)).
