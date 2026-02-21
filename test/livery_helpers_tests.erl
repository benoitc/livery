%% @doc Unit tests for livery_helpers module.
-module(livery_helpers_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("livery/include/livery.hrl").

%%====================================================================
%% Test Fixtures
%%====================================================================

make_req(Opts) ->
    Req = livery_req:new(),
    Req1 = case maps:get(qs, Opts, undefined) of
        undefined -> Req;
        Qs -> livery_req:set_qs(Qs, Req)
    end,
    Req2 = case maps:get(body, Opts, undefined) of
        undefined -> Req1;
        Body -> livery_req:set_body(Body, Req1)
    end,
    Req3 = case maps:get(headers, Opts, undefined) of
        undefined -> Req2;
        Headers -> livery_req:set_headers(Headers, Req2)
    end,
    Req3.

%%====================================================================
%% Query String Tests
%%====================================================================

parse_qs_test_() ->
    [
        {"empty query string",
         fun() ->
             Req = make_req(#{qs => <<>>}),
             ?assertEqual(#{}, livery_helpers:parse_qs(Req))
         end},

        {"single param",
         fun() ->
             Req = make_req(#{qs => <<"foo=bar">>}),
             ?assertEqual(#{<<"foo">> => <<"bar">>}, livery_helpers:parse_qs(Req))
         end},

        {"multiple params",
         fun() ->
             Req = make_req(#{qs => <<"foo=bar&baz=qux">>}),
             ?assertEqual(#{<<"foo">> => <<"bar">>, <<"baz">> => <<"qux">>},
                          livery_helpers:parse_qs(Req))
         end},

        {"url encoded value",
         fun() ->
             Req = make_req(#{qs => <<"message=hello%20world">>}),
             Result = livery_helpers:parse_qs(Req),
             ?assertEqual(<<"hello world">>, maps:get(<<"message">>, Result))
         end}
    ].

get_qs_value_test_() ->
    [
        {"get existing value",
         fun() ->
             Req = make_req(#{qs => <<"name=john">>}),
             ?assertEqual(<<"john">>, livery_helpers:get_qs_value(<<"name">>, Req))
         end},

        {"get missing value returns undefined",
         fun() ->
             Req = make_req(#{qs => <<"name=john">>}),
             ?assertEqual(undefined, livery_helpers:get_qs_value(<<"age">>, Req))
         end},

        {"get missing value returns default",
         fun() ->
             Req = make_req(#{qs => <<"name=john">>}),
             ?assertEqual(<<"25">>, livery_helpers:get_qs_value(<<"age">>, Req, <<"25">>))
         end}
    ].

%%====================================================================
%% Form Parsing Tests
%%====================================================================

parse_form_test_() ->
    [
        {"empty body",
         fun() ->
             Req = make_req(#{body => <<>>}),
             ?assertEqual(#{}, livery_helpers:parse_form(Req))
         end},

        {"undefined body",
         fun() ->
             Req = make_req(#{}),
             ?assertEqual(#{}, livery_helpers:parse_form(Req))
         end},

        {"simple form",
         fun() ->
             Req = make_req(#{body => <<"username=admin&password=secret">>}),
             Result = livery_helpers:parse_form(Req),
             ?assertEqual(<<"admin">>, maps:get(<<"username">>, Result)),
             ?assertEqual(<<"secret">>, maps:get(<<"password">>, Result))
         end}
    ].

%%====================================================================
%% Multipart Tests
%%====================================================================

get_multipart_boundary_test_() ->
    [
        {"extract boundary",
         fun() ->
             Req = make_req(#{headers => [{<<"content-type">>,
                 <<"multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW">>}]}),
             ?assertEqual({ok, <<"----WebKitFormBoundary7MA4YWxkTrZu0gW">>},
                          livery_helpers:get_multipart_boundary(Req))
         end},

        {"boundary with quotes",
         fun() ->
             Req = make_req(#{headers => [{<<"content-type">>,
                 <<"multipart/form-data; boundary=\"myboundary\"">>}]}),
             ?assertEqual({ok, <<"myboundary">>},
                          livery_helpers:get_multipart_boundary(Req))
         end},

        {"no boundary",
         fun() ->
             Req = make_req(#{headers => [{<<"content-type">>, <<"text/plain">>}]}),
             ?assertEqual({error, no_boundary},
                          livery_helpers:get_multipart_boundary(Req))
         end}
    ].

parse_multipart_test_() ->
    [
        {"simple text field",
         fun() ->
             Body = <<"------formbound\r\n",
                      "Content-Disposition: form-data; name=\"field1\"\r\n",
                      "\r\n",
                      "value1\r\n",
                      "------formbound--\r\n">>,
             Req = make_req(#{
                 body => Body,
                 headers => [{<<"content-type">>,
                     <<"multipart/form-data; boundary=----formbound">>}]
             }),
             {ok, Parts} = livery_helpers:parse_multipart(Req),
             ?assertEqual(1, length(Parts)),
             [Part1] = Parts,
             ?assertEqual(<<"field1">>, maps:get(name, Part1)),
             ?assertEqual(<<"value1">>, maps:get(data, Part1))
         end},

        {"file upload",
         fun() ->
             Body = <<"------formbound\r\n",
                      "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n",
                      "Content-Type: text/plain\r\n",
                      "\r\n",
                      "file contents\r\n",
                      "------formbound--\r\n">>,
             Req = make_req(#{
                 body => Body,
                 headers => [{<<"content-type">>,
                     <<"multipart/form-data; boundary=----formbound">>}]
             }),
             {ok, Parts} = livery_helpers:parse_multipart(Req),
             ?assertEqual(1, length(Parts)),
             [Part1] = Parts,
             ?assertEqual(<<"file">>, maps:get(name, Part1)),
             ?assertEqual(<<"test.txt">>, maps:get(filename, Part1)),
             ?assertEqual(<<"text/plain">>, maps:get(content_type, Part1)),
             ?assertEqual(<<"file contents">>, maps:get(data, Part1))
         end}
    ].

%%====================================================================
%% JSON Tests
%%====================================================================

json_body_test_() ->
    [
        {"valid json object",
         fun() ->
             Req = make_req(#{body => <<"{\"name\":\"test\"}">>}),
             ?assertEqual({ok, #{<<"name">> => <<"test">>}},
                          livery_helpers:json_body(Req))
         end},

        {"valid json array",
         fun() ->
             Req = make_req(#{body => <<"[1,2,3]">>}),
             ?assertEqual({ok, [1, 2, 3]}, livery_helpers:json_body(Req))
         end},

        {"invalid json",
         fun() ->
             Req = make_req(#{body => <<"{invalid}">>}),
             {error, _} = livery_helpers:json_body(Req)
         end},

        {"empty body",
         fun() ->
             Req = make_req(#{body => <<>>}),
             ?assertEqual({error, empty_body}, livery_helpers:json_body(Req))
         end},

        {"no body",
         fun() ->
             Req = make_req(#{}),
             ?assertEqual({error, no_body}, livery_helpers:json_body(Req))
         end}
    ].

reply_json_test_() ->
    [
        {"simple json response",
         fun() ->
             State = my_state,
             {reply, 200, Headers, Body, State} =
                 livery_helpers:reply_json(200, #{key => value}, State),
             ?assertEqual({<<"content-type">>, <<"application/json">>},
                          lists:keyfind(<<"content-type">>, 1, Headers)),
             %% Body should be valid JSON
             Decoded = json:decode(iolist_to_binary(Body)),
             ?assertEqual(#{<<"key">> => <<"value">>}, Decoded)
         end},

        {"json with extra headers",
         fun() ->
             State = my_state,
             ExtraHeaders = [{<<"x-custom">>, <<"value">>}],
             {reply, 201, Headers, _Body, State} =
                 livery_helpers:reply_json(201, #{}, ExtraHeaders, State),
             ?assertEqual({<<"x-custom">>, <<"value">>},
                          lists:keyfind(<<"x-custom">>, 1, Headers))
         end}
    ].

%%====================================================================
%% Response Helper Tests
%%====================================================================

reply_text_test() ->
    State = my_state,
    {reply, 200, Headers, <<"Hello">>, State} =
        livery_helpers:reply_text(200, <<"Hello">>, State),
    ?assertEqual({<<"content-type">>, <<"text/plain; charset=utf-8">>},
                 lists:keyfind(<<"content-type">>, 1, Headers)).

reply_html_test() ->
    State = my_state,
    {reply, 200, Headers, <<"<h1>Hi</h1>">>, State} =
        livery_helpers:reply_html(200, <<"<h1>Hi</h1>">>, State),
    ?assertEqual({<<"content-type">>, <<"text/html; charset=utf-8">>},
                 lists:keyfind(<<"content-type">>, 1, Headers)).

reply_redirect_test_() ->
    [
        {"default 302 redirect",
         fun() ->
             State = my_state,
             {reply, 302, Headers, <<>>, State} =
                 livery_helpers:reply_redirect(<<"/new-location">>, State),
             ?assertEqual({<<"location">>, <<"/new-location">>},
                          lists:keyfind(<<"location">>, 1, Headers))
         end},

        {"301 redirect",
         fun() ->
             State = my_state,
             {reply, 301, Headers, <<>>, State} =
                 livery_helpers:reply_redirect(301, <<"/moved">>, State),
             ?assertEqual({<<"location">>, <<"/moved">>},
                          lists:keyfind(<<"location">>, 1, Headers))
         end}
    ].

reply_error_test_() ->
    [
        {"not found",
         fun() ->
             {reply, 404, _, <<"Not Found">>, _} =
                 livery_helpers:reply_not_found(my_state)
         end},

        {"bad request",
         fun() ->
             {reply, 400, _, <<"Invalid input">>, _} =
                 livery_helpers:reply_bad_request(<<"Invalid input">>, my_state)
         end},

        {"internal error",
         fun() ->
             {reply, 500, _, <<"Something went wrong">>, _} =
                 livery_helpers:reply_internal_error(<<"Something went wrong">>, my_state)
         end}
    ].

%%====================================================================
%% Cookie Tests
%%====================================================================

get_cookie_test_() ->
    [
        {"get existing cookie",
         fun() ->
             Req = make_req(#{headers => [{<<"cookie">>, <<"session=abc123; user=john">>}]}),
             ?assertEqual(<<"abc123">>, livery_helpers:get_cookie(<<"session">>, Req))
         end},

        {"get missing cookie returns undefined",
         fun() ->
             Req = make_req(#{headers => [{<<"cookie">>, <<"session=abc123">>}]}),
             ?assertEqual(undefined, livery_helpers:get_cookie(<<"missing">>, Req))
         end},

        {"get missing cookie returns default",
         fun() ->
             Req = make_req(#{headers => [{<<"cookie">>, <<"session=abc123">>}]}),
             ?assertEqual(<<"default">>,
                          livery_helpers:get_cookie(<<"missing">>, Req, <<"default">>))
         end},

        {"no cookie header",
         fun() ->
             Req = make_req(#{}),
             ?assertEqual(undefined, livery_helpers:get_cookie(<<"session">>, Req))
         end}
    ].

set_cookie_test_() ->
    [
        {"simple cookie",
         fun() ->
             {<<"set-cookie">>, Cookie} =
                 livery_helpers:set_cookie(<<"name">>, <<"value">>, #{}),
             ?assertEqual(<<"name=value">>, Cookie)
         end},

        {"cookie with path",
         fun() ->
             {<<"set-cookie">>, Cookie} =
                 livery_helpers:set_cookie(<<"name">>, <<"value">>, #{path => <<"/">>}),
             ?assert(binary:match(Cookie, <<"; Path=/">>) =/= nomatch)
         end},

        {"cookie with max age",
         fun() ->
             {<<"set-cookie">>, Cookie} =
                 livery_helpers:set_cookie(<<"name">>, <<"value">>, #{max_age => 3600}),
             ?assert(binary:match(Cookie, <<"; Max-Age=3600">>) =/= nomatch)
         end},

        {"secure http-only cookie",
         fun() ->
             {<<"set-cookie">>, Cookie} =
                 livery_helpers:set_cookie(<<"name">>, <<"value">>,
                     #{secure => true, http_only => true}),
             ?assert(binary:match(Cookie, <<"; Secure">>) =/= nomatch),
             ?assert(binary:match(Cookie, <<"; HttpOnly">>) =/= nomatch)
         end},

        {"same site strict",
         fun() ->
             {<<"set-cookie">>, Cookie} =
                 livery_helpers:set_cookie(<<"name">>, <<"value">>, #{same_site => strict}),
             ?assert(binary:match(Cookie, <<"; SameSite=Strict">>) =/= nomatch)
         end}
    ].

delete_cookie_test() ->
    {<<"set-cookie">>, Cookie} = livery_helpers:delete_cookie(<<"session">>),
    ?assert(binary:match(Cookie, <<"; Max-Age=0">>) =/= nomatch).

%%====================================================================
%% Path Bindings Tests
%%====================================================================

binding_test_() ->
    [
        {"get existing binding",
         fun() ->
             Opts = #{bindings => #{<<"id">> => <<"123">>}},
             ?assertEqual(<<"123">>, livery_helpers:binding(<<"id">>, Opts))
         end},

        {"get missing binding returns undefined",
         fun() ->
             Opts = #{bindings => #{<<"id">> => <<"123">>}},
             ?assertEqual(undefined, livery_helpers:binding(<<"name">>, Opts))
         end},

        {"get missing binding returns default",
         fun() ->
             Opts = #{bindings => #{}},
             ?assertEqual(<<"default">>,
                          livery_helpers:binding(<<"name">>, Opts, <<"default">>))
         end},

        {"no bindings in opts",
         fun() ->
             Opts = #{},
             ?assertEqual(undefined, livery_helpers:binding(<<"id">>, Opts))
         end},

        {"non-map opts",
         fun() ->
             Opts = [],
             ?assertEqual(<<"default">>,
                          livery_helpers:binding(<<"id">>, Opts, <<"default">>))
         end}
    ].

bindings_test_() ->
    [
        {"get all bindings",
         fun() ->
             Opts = #{bindings => #{<<"id">> => <<"123">>, <<"name">> => <<"john">>}},
             ?assertEqual(#{<<"id">> => <<"123">>, <<"name">> => <<"john">>},
                          livery_helpers:bindings(Opts))
         end},

        {"no bindings returns empty map",
         fun() ->
             Opts = #{},
             ?assertEqual(#{}, livery_helpers:bindings(Opts))
         end}
    ].

%%====================================================================
%% Content Negotiation Tests
%%====================================================================

accepts_test_() ->
    [
        {"accepts specific type",
         fun() ->
             Req = make_req(#{headers => [{<<"accept">>, <<"application/json">>}]}),
             ?assert(livery_helpers:accepts(<<"application/json">>, Req)),
             ?assertNot(livery_helpers:accepts(<<"text/html">>, Req))
         end},

        {"accepts wildcard",
         fun() ->
             Req = make_req(#{headers => [{<<"accept">>, <<"*/*">>}]}),
             ?assert(livery_helpers:accepts(<<"application/json">>, Req)),
             ?assert(livery_helpers:accepts(<<"text/html">>, Req))
         end},

        {"accepts type wildcard",
         fun() ->
             Req = make_req(#{headers => [{<<"accept">>, <<"text/*">>}]}),
             ?assert(livery_helpers:accepts(<<"text/html">>, Req)),
             ?assert(livery_helpers:accepts(<<"text/plain">>, Req)),
             ?assertNot(livery_helpers:accepts(<<"application/json">>, Req))
         end},

        {"no accept header accepts anything",
         fun() ->
             Req = make_req(#{}),
             ?assert(livery_helpers:accepts(<<"application/json">>, Req)),
             ?assert(livery_helpers:accepts(<<"text/html">>, Req))
         end}
    ].

accepts_json_test() ->
    Req = make_req(#{headers => [{<<"accept">>, <<"application/json">>}]}),
    ?assert(livery_helpers:accepts_json(Req)).

accepts_html_test() ->
    Req = make_req(#{headers => [{<<"accept">>, <<"text/html">>}]}),
    ?assert(livery_helpers:accepts_html(Req)).

preferred_type_test_() ->
    [
        {"prefer first matching type",
         fun() ->
             Req = make_req(#{headers =>
                 [{<<"accept">>, <<"text/html, application/json;q=0.9">>}]}),
             Types = [<<"application/json">>, <<"text/html">>],
             ?assertEqual(<<"text/html">>, livery_helpers:preferred_type(Types, Req))
         end},

        {"respect quality values",
         fun() ->
             Req = make_req(#{headers =>
                 [{<<"accept">>, <<"text/html;q=0.5, application/json;q=0.9">>}]}),
             Types = [<<"text/html">>, <<"application/json">>],
             ?assertEqual(<<"application/json">>, livery_helpers:preferred_type(Types, Req))
         end},

        {"no accept header returns first type",
         fun() ->
             Req = make_req(#{}),
             Types = [<<"application/json">>, <<"text/html">>],
             ?assertEqual(<<"application/json">>, livery_helpers:preferred_type(Types, Req))
         end},

        {"no matching type returns undefined",
         fun() ->
             Req = make_req(#{headers => [{<<"accept">>, <<"application/xml">>}]}),
             Types = [<<"application/json">>, <<"text/html">>],
             ?assertEqual(undefined, livery_helpers:preferred_type(Types, Req))
         end}
    ].
