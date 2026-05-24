-module(livery_ext_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").
-include("livery.hrl").

%%====================================================================
%% JSON
%%====================================================================

json_buffered_object_test() ->
    Req = with_body(<<"{\"a\":1,\"b\":\"x\"}">>),
    ?assertEqual(
        {ok, #{<<"a">> => 1, <<"b">> => <<"x">>}},
        livery_ext:json(Req)
    ).

json_empty_body_test() ->
    ?assertEqual({error, no_body}, livery_ext:json(req())).

json_invalid_test() ->
    ?assertEqual(
        {error, invalid_json},
        livery_ext:json(with_body(<<"not json">>))
    ).

json_stream_body_not_buffered_test() ->
    Req = livery_req:set_body({stream, fake_reader}, req()),
    ?assertEqual({error, not_buffered}, livery_ext:json(Req)).

%%====================================================================
%% Form
%%====================================================================

form_basic_test() ->
    Req = with_body(<<"a=1&b=two&c=">>),
    ?assertEqual(
        {ok, [{<<"a">>, <<"1">>}, {<<"b">>, <<"two">>}, {<<"c">>, <<>>}]},
        livery_ext:form(Req)
    ).

form_url_decoding_test() ->
    Req = with_body(<<"name=hello%20world&plus=a+b&pct=100%25">>),
    ?assertEqual(
        {ok, [
            {<<"name">>, <<"hello world">>},
            {<<"plus">>, <<"a b">>},
            {<<"pct">>, <<"100%">>}
        ]},
        livery_ext:form(Req)
    ).

form_empty_body_test() ->
    ?assertEqual({error, no_body}, livery_ext:form(req())).

%%====================================================================
%% Path parameter
%%====================================================================

path_param_test() ->
    Req = livery_req:set_bindings(#{<<"name">> => <<"alice">>}, req()),
    ?assertEqual(<<"alice">>, livery_ext:path_param(<<"name">>, Req)),
    ?assertEqual(undefined, livery_ext:path_param(<<"missing">>, Req)).

%%====================================================================
%% Query
%%====================================================================

query_simple_test() ->
    Req = req_with_query(<<"a=1&b=two">>),
    ?assertEqual(<<"1">>, livery_ext:query(<<"a">>, Req)),
    ?assertEqual(<<"two">>, livery_ext:query(<<"b">>, Req)),
    ?assertEqual(undefined, livery_ext:query(<<"missing">>, Req)).

query_url_decoded_test() ->
    Req = req_with_query(<<"q=hello%20world">>),
    ?assertEqual(<<"hello world">>, livery_ext:query(<<"q">>, Req)).

query_empty_test() ->
    ?assertEqual(undefined, livery_ext:query(<<"a">>, req())).

%%====================================================================
%% Header
%%====================================================================

header_case_insensitive_test() ->
    Req = livery_req:new(#{
        protocol => h1,
        method => <<"GET">>,
        path => <<"/">>,
        headers => [{<<"X-Custom">>, <<"v">>}]
    }),
    ?assertEqual(<<"v">>, livery_ext:header(<<"x-custom">>, Req)),
    ?assertEqual(<<"v">>, livery_ext:header(<<"X-Custom">>, Req)),
    ?assertEqual(undefined, livery_ext:header(<<"missing">>, Req)).

%%====================================================================
%% Bearer token
%%====================================================================

bearer_token_present_test() ->
    Req = req_with_auth(<<"Bearer abc.def.ghi">>),
    ?assertEqual(<<"abc.def.ghi">>, livery_ext:bearer_token(Req)).

bearer_token_lowercase_scheme_test() ->
    ?assertEqual(
        <<"tok">>,
        livery_ext:bearer_token(req_with_auth(<<"bearer tok">>))
    ),
    ?assertEqual(
        <<"tok">>,
        livery_ext:bearer_token(req_with_auth(<<"BEARER tok">>))
    ).

bearer_token_missing_test() ->
    ?assertEqual(undefined, livery_ext:bearer_token(req())).

bearer_token_wrong_scheme_test() ->
    ?assertEqual(
        undefined,
        livery_ext:bearer_token(req_with_auth(<<"Basic dXNlcjpwYXNz">>))
    ).

%%====================================================================
%% JSON edge cases
%%====================================================================

json_array_test() ->
    ?assertEqual(
        {ok, [1, 2, 3]},
        livery_ext:json(with_body(<<"[1,2,3]">>))
    ).

json_primitive_string_test() ->
    ?assertEqual(
        {ok, <<"plain">>},
        livery_ext:json(with_body(<<"\"plain\"">>))
    ).

json_primitive_null_test() ->
    ?assertEqual({ok, null}, livery_ext:json(with_body(<<"null">>))).

json_bool_test() ->
    ?assertEqual({ok, true}, livery_ext:json(with_body(<<"true">>))),
    ?assertEqual({ok, false}, livery_ext:json(with_body(<<"false">>))).

%%====================================================================
%% Form edge cases
%%====================================================================

form_strips_empty_pairs_test() ->
    Req = with_body(<<"a=1&&b=2&">>),
    ?assertEqual(
        {ok, [{<<"a">>, <<"1">>}, {<<"b">>, <<"2">>}]},
        livery_ext:form(Req)
    ).

form_key_without_value_test() ->
    Req = with_body(<<"flag">>),
    ?assertEqual({ok, [{<<"flag">>, <<>>}]}, livery_ext:form(Req)).

form_malformed_percent_passes_through_test() ->
    %% Bad escapes are kept verbatim rather than failing the whole body.
    Req = with_body(<<"a=%ZZ">>),
    ?assertEqual({ok, [{<<"a">>, <<"%ZZ">>}]}, livery_ext:form(Req)).

%%====================================================================
%% read_form (streaming urlencoded)
%%====================================================================

read_form_buffered_test() ->
    Req = form_req(<<"a=1&b=two+words&c=%2F">>),
    ?assertEqual(
        {ok, [{<<"a">>, <<"1">>}, {<<"b">>, <<"two words">>}, {<<"c">>, <<"/">>}]},
        livery_ext:read_form(Req)
    ).

read_form_stream_test() ->
    Req = form_stream_req([<<"a=1&">>, <<"b=2">>]),
    ?assertEqual(
        {ok, [{<<"a">>, <<"1">>}, {<<"b">>, <<"2">>}]},
        livery_ext:read_form(Req)
    ).

read_form_case_insensitive_ct_test() ->
    Req = ct_req(
        <<"Application/X-WWW-Form-Urlencoded; charset=utf-8">>,
        {buffered, <<"a=1">>}
    ),
    ?assertEqual({ok, [{<<"a">>, <<"1">>}]}, livery_ext:read_form(Req)).

read_form_malformed_escape_verbatim_test() ->
    Req = form_req(<<"a=%ZZ">>),
    ?assertEqual({ok, [{<<"a">>, <<"%ZZ">>}]}, livery_ext:read_form(Req)).

read_form_wrong_content_type_test() ->
    Req = ct_req(<<"application/json">>, {buffered, <<"a=1">>}),
    ?assertEqual({error, not_form}, livery_ext:read_form(Req)).

read_form_no_content_type_test() ->
    ?assertEqual({error, not_form}, livery_ext:read_form(with_body(<<"a=1">>))).

read_form_empty_body_test() ->
    Req = ct_req(<<"application/x-www-form-urlencoded">>, empty),
    ?assertEqual({error, no_body}, livery_ext:read_form(Req)).

read_form_max_size_buffered_test() ->
    Req = form_req(<<"a=1234567890">>),
    ?assertEqual(
        {error, {limit, max_size}},
        livery_ext:read_form(Req, #{max_size => 4})
    ).

read_form_max_size_stream_test() ->
    Req = form_stream_req([<<"aaaa">>, <<"bbbb">>, <<"cccc">>]),
    ?assertEqual(
        {error, {limit, max_size}},
        livery_ext:read_form(Req, #{max_size => 5})
    ).

%%====================================================================
%% Helpers
%%====================================================================

req() ->
    livery_req:new(#{protocol => h1, method => <<"GET">>, path => <<"/">>}).

with_body(Bin) ->
    livery_req:set_body({buffered, Bin}, req()).

req_with_query(RawQuery) ->
    livery_req:new(#{
        protocol => h1,
        method => <<"GET">>,
        path => <<"/">>,
        raw_query => RawQuery
    }).

req_with_auth(Value) ->
    livery_req:new(#{
        protocol => h1,
        method => <<"GET">>,
        path => <<"/">>,
        headers => [{<<"authorization">>, Value}]
    }).

ct_req(ContentType, Body) ->
    livery_req:new(#{
        protocol => h1,
        method => <<"POST">>,
        path => <<"/">>,
        headers => [{<<"content-type">>, ContentType}],
        body => Body
    }).

form_req(Bin) ->
    ct_req(<<"application/x-www-form-urlencoded">>, {buffered, Bin}).

form_stream_req(Chunks) ->
    Ref = make_ref(),
    [self() ! {livery_body, Ref, {data, C}} || C <- Chunks],
    self() ! {livery_body, Ref, eof},
    ct_req(<<"application/x-www-form-urlencoded">>, {stream, livery_body:new(Ref)}).
