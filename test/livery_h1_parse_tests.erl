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
