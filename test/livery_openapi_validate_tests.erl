-module(livery_openapi_validate_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% validate/2
%%====================================================================

accepts_valid_object_test() ->
    Schema = #{
        type => <<"object">>,
        required => [<<"email">>],
        properties => #{
            <<"email">> => #{type => <<"string">>},
            <<"age">>   => #{type => <<"integer">>, minimum => 0}
        }
    },
    ?assertEqual(ok, livery_openapi_validate:validate(
        #{<<"email">> => <<"a@b.c">>, <<"age">> => 30}, Schema)).

rejects_missing_required_test() ->
    Schema = #{type => <<"object">>, required => [<<"email">>]},
    ?assertMatch({error, [{<<"$.email">>, _}]},
                 livery_openapi_validate:validate(#{}, Schema)).

rejects_wrong_type_test() ->
    Schema = #{type => <<"object">>,
               properties => #{<<"age">> => #{type => <<"integer">>}}},
    ?assertMatch({error, [{<<"$.age">>, _}]},
                 livery_openapi_validate:validate(
                     #{<<"age">> => <<"old">>}, Schema)).

enforces_minimum_test() ->
    Schema = #{type => <<"integer">>, minimum => 1},
    ?assertEqual(ok, livery_openapi_validate:validate(5, Schema)),
    ?assertMatch({error, [{<<"$">>, _}]},
                 livery_openapi_validate:validate(0, Schema)).

enforces_string_length_test() ->
    Schema = #{type => <<"string">>, minLength => 2, maxLength => 4},
    ?assertEqual(ok, livery_openapi_validate:validate(<<"abc">>, Schema)),
    ?assertMatch({error, _}, livery_openapi_validate:validate(<<"a">>, Schema)),
    ?assertMatch({error, _}, livery_openapi_validate:validate(<<"abcde">>, Schema)).

enforces_enum_test() ->
    Schema = #{enum => [<<"red">>, <<"green">>]},
    ?assertEqual(ok, livery_openapi_validate:validate(<<"red">>, Schema)),
    ?assertMatch({error, _},
                 livery_openapi_validate:validate(<<"blue">>, Schema)).

validates_array_items_test() ->
    Schema = #{type => <<"array">>,
               items => #{type => <<"integer">>}},
    ?assertEqual(ok, livery_openapi_validate:validate([1, 2, 3], Schema)),
    ?assertMatch({error, [{<<"$[1]">>, _}]},
                 livery_openapi_validate:validate([1, <<"x">>, 3], Schema)).

nested_object_path_test() ->
    Schema = #{
        type => <<"object">>,
        properties => #{
            <<"user">> => #{
                type => <<"object">>,
                required => [<<"id">>]
            }
        }
    },
    ?assertMatch({error, [{<<"$.user.id">>, _}]},
                 livery_openapi_validate:validate(
                     #{<<"user">> => #{}}, Schema)).

%%====================================================================
%% Middleware
%%====================================================================

middleware_accepts_valid_body_test() ->
    Schema = #{type => <<"object">>, required => [<<"name">>]},
    Stack = [{livery_openapi_validate, #{body_schema => Schema}}],
    Handler = fun(R) ->
        #{<<"name">> := N} = livery_req:meta(body, R),
        livery_resp:text(200, N)
    end,
    Cap = livery_test_adapter:run(Stack, Handler,
        #{method => <<"POST">>,
          body => {buffered, <<"{\"name\":\"ada\"}">>}}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"ada">>, livery_test_adapter:body(Cap)).

middleware_rejects_invalid_body_test() ->
    Schema = #{type => <<"object">>, required => [<<"name">>]},
    Stack = [{livery_openapi_validate, #{body_schema => Schema}}],
    Cap = livery_test_adapter:run(Stack,
        fun(_R) -> error(must_not_be_called) end,
        #{method => <<"POST">>, body => {buffered, <<"{}">>}}),
    ?assertEqual(422, livery_test_adapter:status(Cap)),
    Decoded = json:decode(livery_test_adapter:body(Cap)),
    ?assertMatch(#{<<"errors">> := [_ | _]}, Decoded).

middleware_rejects_malformed_json_test() ->
    Stack = [{livery_openapi_validate, #{body_schema => #{}}}],
    Cap = livery_test_adapter:run(Stack,
        fun(_R) -> error(must_not_be_called) end,
        #{method => <<"POST">>, body => {buffered, <<"not json">>}}),
    ?assertEqual(400, livery_test_adapter:status(Cap)).

%%====================================================================
%% Redoc UI handler
%%====================================================================

redoc_handler_serves_html_test() ->
    Handler = livery_openapi:redoc_handler(),
    Cap = livery_test_adapter:run([], Handler, #{path => <<"/docs">>}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"text/html; charset=utf-8">>,
                 livery_test_adapter:header(<<"content-type">>, Cap)),
    Body = livery_test_adapter:body(Cap),
    ?assertNotEqual(nomatch, binary:match(Body, <<"redoc">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"/openapi.json">>)).

redoc_handler_custom_spec_url_test() ->
    Handler = livery_openapi:redoc_handler(<<"/v2/openapi.json">>),
    Cap = livery_test_adapter:run([], Handler, #{}),
    Body = livery_test_adapter:body(Cap),
    ?assertNotEqual(nomatch, binary:match(Body, <<"/v2/openapi.json">>)).
