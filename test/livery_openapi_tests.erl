-module(livery_openapi_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% build/1
%%====================================================================

emits_openapi_31_and_info_test() ->
    Doc = livery_openapi:build(#{
        info => #{title => <<"My API">>, version => <<"2.1.0">>},
        routes => []
    }),
    ?assertEqual(<<"3.1.0">>, maps:get(<<"openapi">>, Doc)),
    ?assertEqual(
        #{<<"title">> => <<"My API">>, <<"version">> => <<"2.1.0">>},
        maps:get(<<"info">>, Doc)
    ),
    ?assertEqual(#{}, maps:get(<<"paths">>, Doc)).

simple_get_route_test() ->
    Doc = livery_openapi:build(#{
        info => #{title => <<"A">>, version => <<"1">>},
        routes => [{<<"GET">>, <<"/health">>, {h, ok}}]
    }),
    Paths = maps:get(<<"paths">>, Doc),
    ?assert(maps:is_key(<<"/health">>, Paths)),
    Get = maps:get(<<"get">>, maps:get(<<"/health">>, Paths)),
    %% Default 200 response when no metadata.
    ?assertMatch(
        #{<<"200">> := #{<<"description">> := <<"OK">>}},
        maps:get(<<"responses">>, Get)
    ).

path_param_becomes_template_and_parameter_test() ->
    Doc = livery_openapi:build(#{
        info => #{title => <<"A">>, version => <<"1">>},
        routes => [{<<"GET">>, <<"/users/:id">>, {users, show}}]
    }),
    Paths = maps:get(<<"paths">>, Doc),
    ?assert(maps:is_key(<<"/users/{id}">>, Paths)),
    Get = maps:get(<<"get">>, maps:get(<<"/users/{id}">>, Paths)),
    [Param] = maps:get(<<"parameters">>, Get),
    ?assertEqual(<<"id">>, maps:get(<<"name">>, Param)),
    ?assertEqual(<<"path">>, maps:get(<<"in">>, Param)),
    ?assertEqual(true, maps:get(<<"required">>, Param)).

wildcard_becomes_template_test() ->
    Doc = livery_openapi:build(#{
        info => #{title => <<"A">>, version => <<"1">>},
        routes => [{<<"GET">>, <<"/files/*rest">>, {files, serve}}]
    }),
    Paths = maps:get(<<"paths">>, Doc),
    ?assert(maps:is_key(<<"/files/{rest}">>, Paths)).

metadata_populates_operation_test() ->
    Doc = livery_openapi:build(#{
        info => #{title => <<"A">>, version => <<"1">>},
        routes => [
            {<<"POST">>, <<"/items">>, {items, create}, #{
                operation_id => <<"createItem">>,
                summary => <<"Create an item">>,
                tags => [<<"items">>],
                request_body => #{<<"required">> => true},
                responses => #{201 => #{description => <<"created">>}}
            }}
        ]
    }),
    Post = maps:get(
        <<"post">>,
        maps:get(<<"/items">>, maps:get(<<"paths">>, Doc))
    ),
    ?assertEqual(<<"createItem">>, maps:get(<<"operationId">>, Post)),
    ?assertEqual(<<"Create an item">>, maps:get(<<"summary">>, Post)),
    ?assertEqual([<<"items">>], maps:get(<<"tags">>, Post)),
    ?assertMatch(#{<<"required">> := true}, maps:get(<<"requestBody">>, Post)),
    ?assertMatch(
        #{<<"201">> := #{<<"description">> := <<"created">>}},
        maps:get(<<"responses">>, Post)
    ).

multiple_methods_same_path_test() ->
    Doc = livery_openapi:build(#{
        info => #{title => <<"A">>, version => <<"1">>},
        routes => [
            {<<"GET">>, <<"/items">>, {items, index}},
            {<<"POST">>, <<"/items">>, {items, create}}
        ]
    }),
    Item = maps:get(<<"/items">>, maps:get(<<"paths">>, Doc)),
    ?assert(maps:is_key(<<"get">>, Item)),
    ?assert(maps:is_key(<<"post">>, Item)).

servers_included_when_given_test() ->
    Doc = livery_openapi:build(#{
        info => #{title => <<"A">>, version => <<"1">>},
        routes => [],
        servers => [#{<<"url">> => <<"https://api.example">>}]
    }),
    ?assertEqual(
        [#{<<"url">> => <<"https://api.example">>}],
        maps:get(<<"servers">>, Doc)
    ).

%%====================================================================
%% to_json/1 + handler/1
%%====================================================================

to_json_roundtrips_test() ->
    Doc = livery_openapi:build(#{
        info => #{title => <<"A">>, version => <<"1">>},
        routes => [{<<"GET">>, <<"/">>, {h, ok}}]
    }),
    Json = livery_openapi:to_json(Doc),
    ?assert(is_binary(Json)),
    Decoded = json:decode(Json),
    ?assertEqual(<<"3.1.0">>, maps:get(<<"openapi">>, Decoded)).

handler_serves_json_test() ->
    Doc = livery_openapi:build(#{
        info => #{title => <<"A">>, version => <<"1">>},
        routes => []
    }),
    Handler = livery_openapi:handler(Doc),
    Cap = livery_test_adapter:run([], Handler, #{path => <<"/openapi.json">>}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(
        <<"application/json">>,
        livery_test_adapter:header(<<"content-type">>, Cap)
    ),
    Decoded = json:decode(livery_test_adapter:body(Cap)),
    ?assertEqual(<<"3.1.0">>, maps:get(<<"openapi">>, Decoded)).
