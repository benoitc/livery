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
            <<"age">> => #{type => <<"integer">>, minimum => 0}
        }
    },
    ?assertEqual(
        ok,
        livery_openapi_validate:validate(
            #{<<"email">> => <<"a@b.c">>, <<"age">> => 30}, Schema
        )
    ).

rejects_missing_required_test() ->
    Schema = #{type => <<"object">>, required => [<<"email">>]},
    ?assertMatch(
        {error, [{<<"$.email">>, _}]},
        livery_openapi_validate:validate(#{}, Schema)
    ).

rejects_wrong_type_test() ->
    Schema = #{
        type => <<"object">>,
        properties => #{<<"age">> => #{type => <<"integer">>}}
    },
    ?assertMatch(
        {error, [{<<"$.age">>, _}]},
        livery_openapi_validate:validate(
            #{<<"age">> => <<"old">>}, Schema
        )
    ).

enforces_minimum_test() ->
    Schema = #{type => <<"integer">>, minimum => 1},
    ?assertEqual(ok, livery_openapi_validate:validate(5, Schema)),
    ?assertMatch(
        {error, [{<<"$">>, _}]},
        livery_openapi_validate:validate(0, Schema)
    ).

enforces_string_length_test() ->
    Schema = #{type => <<"string">>, minLength => 2, maxLength => 4},
    ?assertEqual(ok, livery_openapi_validate:validate(<<"abc">>, Schema)),
    ?assertMatch({error, _}, livery_openapi_validate:validate(<<"a">>, Schema)),
    ?assertMatch({error, _}, livery_openapi_validate:validate(<<"abcde">>, Schema)).

enforces_enum_test() ->
    Schema = #{enum => [<<"red">>, <<"green">>]},
    ?assertEqual(ok, livery_openapi_validate:validate(<<"red">>, Schema)),
    ?assertMatch(
        {error, _},
        livery_openapi_validate:validate(<<"blue">>, Schema)
    ).

validates_array_items_test() ->
    Schema = #{
        type => <<"array">>,
        items => #{type => <<"integer">>}
    },
    ?assertEqual(ok, livery_openapi_validate:validate([1, 2, 3], Schema)),
    ?assertMatch(
        {error, [{<<"$[1]">>, _}]},
        livery_openapi_validate:validate([1, <<"x">>, 3], Schema)
    ).

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
    ?assertMatch(
        {error, [{<<"$.user.id">>, _}]},
        livery_openapi_validate:validate(
            #{<<"user">> => #{}}, Schema
        )
    ).

%%====================================================================
%% Expanded keywords
%%====================================================================

-define(V(Val, Schema), livery_openapi_validate:validate(Val, Schema)).

enforces_const_test() ->
    Schema = #{const => <<"v1">>},
    ?assertEqual(ok, ?V(<<"v1">>, Schema)),
    ?assertMatch({error, _}, ?V(<<"v2">>, Schema)).

enforces_exclusive_bounds_test() ->
    Schema = #{
        type => <<"number">>,
        exclusiveMinimum => 0,
        exclusiveMaximum => 10
    },
    ?assertEqual(ok, ?V(5, Schema)),
    ?assertMatch({error, _}, ?V(0, Schema)),
    ?assertMatch({error, _}, ?V(10, Schema)).

enforces_multiple_of_test() ->
    Schema = #{type => <<"integer">>, multipleOf => 5},
    ?assertEqual(ok, ?V(15, Schema)),
    ?assertMatch({error, _}, ?V(7, Schema)).

enforces_pattern_test() ->
    Schema = #{type => <<"string">>, pattern => <<"^[a-z]+$">>},
    ?assertEqual(ok, ?V(<<"abc">>, Schema)),
    ?assertMatch({error, _}, ?V(<<"abc1">>, Schema)).

accepts_type_union_test() ->
    Schema = #{type => [<<"string">>, <<"null">>]},
    ?assertEqual(ok, ?V(<<"x">>, Schema)),
    ?assertEqual(ok, ?V(null, Schema)),
    ?assertMatch({error, _}, ?V(42, Schema)).

enforces_array_size_test() ->
    Schema = #{type => <<"array">>, minItems => 1, maxItems => 2},
    ?assertEqual(ok, ?V([1], Schema)),
    ?assertMatch({error, _}, ?V([], Schema)),
    ?assertMatch({error, _}, ?V([1, 2, 3], Schema)).

enforces_unique_items_test() ->
    Schema = #{type => <<"array">>, uniqueItems => true},
    ?assertEqual(ok, ?V([1, 2, 3], Schema)),
    ?assertMatch({error, _}, ?V([1, 1, 2], Schema)).

enforces_property_count_test() ->
    Schema = #{type => <<"object">>, minProperties => 1, maxProperties => 2},
    ?assertEqual(ok, ?V(#{<<"a">> => 1}, Schema)),
    ?assertMatch({error, _}, ?V(#{}, Schema)),
    ?assertMatch(
        {error, _},
        ?V(#{<<"a">> => 1, <<"b">> => 2, <<"c">> => 3}, Schema)
    ).

rejects_additional_properties_test() ->
    Schema = #{
        type => <<"object">>,
        properties => #{<<"a">> => #{type => <<"integer">>}},
        additionalProperties => false
    },
    ?assertEqual(ok, ?V(#{<<"a">> => 1}, Schema)),
    ?assertMatch(
        {error, [{<<"$.b">>, _}]},
        ?V(#{<<"a">> => 1, <<"b">> => 2}, Schema)
    ).

validates_additional_properties_schema_test() ->
    Schema = #{
        type => <<"object">>,
        properties => #{<<"a">> => #{type => <<"integer">>}},
        additionalProperties => #{type => <<"string">>}
    },
    ?assertEqual(ok, ?V(#{<<"a">> => 1, <<"b">> => <<"ok">>}, Schema)),
    ?assertMatch(
        {error, [{<<"$.b">>, _}]},
        ?V(#{<<"a">> => 1, <<"b">> => 2}, Schema)
    ).

enforces_all_of_test() ->
    Schema = #{
        allOf => [
            #{type => <<"integer">>},
            #{minimum => 10}
        ]
    },
    ?assertEqual(ok, ?V(15, Schema)),
    ?assertMatch({error, _}, ?V(5, Schema)).

enforces_any_of_test() ->
    Schema = #{
        anyOf => [
            #{type => <<"string">>},
            #{type => <<"integer">>}
        ]
    },
    ?assertEqual(ok, ?V(<<"x">>, Schema)),
    ?assertEqual(ok, ?V(7, Schema)),
    ?assertMatch({error, _}, ?V(true, Schema)).

enforces_one_of_test() ->
    Schema = #{
        oneOf => [
            #{type => <<"integer">>, minimum => 0},
            #{type => <<"integer">>, maximum => 5}
        ]
    },
    %% 10 matches only the first; -1 matches only the second.
    ?assertEqual(ok, ?V(10, Schema)),
    ?assertEqual(ok, ?V(-1, Schema)),
    %% 3 matches both -> not exactly one.
    ?assertMatch({error, _}, ?V(3, Schema)).

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
    Cap = livery_test_adapter:run(
        Stack,
        Handler,
        #{
            method => <<"POST">>,
            body => {buffered, <<"{\"name\":\"ada\"}">>}
        }
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"ada">>, livery_test_adapter:body(Cap)).

middleware_rejects_invalid_body_test() ->
    Schema = #{type => <<"object">>, required => [<<"name">>]},
    Stack = [{livery_openapi_validate, #{body_schema => Schema}}],
    Cap = livery_test_adapter:run(
        Stack,
        fun(_R) -> error(must_not_be_called) end,
        #{method => <<"POST">>, body => {buffered, <<"{}">>}}
    ),
    ?assertEqual(422, livery_test_adapter:status(Cap)),
    Decoded = json:decode(livery_test_adapter:body(Cap)),
    ?assertMatch(#{<<"errors">> := [_ | _]}, Decoded).

middleware_rejects_malformed_json_test() ->
    Stack = [{livery_openapi_validate, #{body_schema => #{}}}],
    Cap = livery_test_adapter:run(
        Stack,
        fun(_R) -> error(must_not_be_called) end,
        #{method => <<"POST">>, body => {buffered, <<"not json">>}}
    ),
    ?assertEqual(400, livery_test_adapter:status(Cap)).

%%====================================================================
%% Redoc UI handler
%%====================================================================

redoc_handler_serves_html_test() ->
    Handler = livery_openapi:redoc_handler(),
    Cap = livery_test_adapter:run([], Handler, #{path => <<"/docs">>}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(
        <<"text/html; charset=utf-8">>,
        livery_test_adapter:header(<<"content-type">>, Cap)
    ),
    Body = livery_test_adapter:body(Cap),
    ?assertNotEqual(nomatch, binary:match(Body, <<"redoc">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"/openapi.json">>)).

redoc_handler_custom_spec_url_test() ->
    Handler = livery_openapi:redoc_handler(<<"/v2/openapi.json">>),
    Cap = livery_test_adapter:run([], Handler, #{}),
    Body = livery_test_adapter:body(Cap),
    ?assertNotEqual(nomatch, binary:match(Body, <<"/v2/openapi.json">>)).

%%====================================================================
%% Swagger UI handler
%%====================================================================

swagger_ui_handler_serves_html_test() ->
    Handler = livery_openapi:swagger_ui_handler(),
    Cap = livery_test_adapter:run([], Handler, #{path => <<"/docs">>}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(
        <<"text/html; charset=utf-8">>,
        livery_test_adapter:header(<<"content-type">>, Cap)
    ),
    Body = livery_test_adapter:body(Cap),
    ?assertNotEqual(nomatch, binary:match(Body, <<"SwaggerUIBundle">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"/openapi.json">>)).

swagger_ui_handler_custom_spec_url_test() ->
    Handler = livery_openapi:swagger_ui_handler(<<"/v2/openapi.json">>),
    Cap = livery_test_adapter:run([], Handler, #{}),
    Body = livery_test_adapter:body(Cap),
    ?assertNotEqual(nomatch, binary:match(Body, <<"/v2/openapi.json">>)).
