-module(livery_router_tests).

-include_lib("eunit/include/eunit.hrl").

static_match_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/">>, root},
        {<<"GET">>, <<"/users/new">>, users_new}
    ]),
    ?assertEqual(
        {ok, root, #{}, undefined},
        livery_router:match(<<"GET">>, <<"/">>, R)
    ),
    ?assertEqual(
        {ok, users_new, #{}, undefined},
        livery_router:match(<<"GET">>, <<"/users/new">>, R)
    ).

param_match_captures_binding_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/users/:id">>, user_show}
    ]),
    ?assertEqual(
        {ok, user_show, #{<<"id">> => <<"42">>}, undefined},
        livery_router:match(<<"GET">>, <<"/users/42">>, R)
    ).

static_wins_over_param_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/users/new">>, users_new},
        {<<"GET">>, <<"/users/:id">>, user_show}
    ]),
    ?assertMatch(
        {ok, users_new, _, _},
        livery_router:match(<<"GET">>, <<"/users/new">>, R)
    ),
    ?assertMatch(
        {ok, user_show, #{<<"id">> := <<"42">>}, _},
        livery_router:match(<<"GET">>, <<"/users/42">>, R)
    ).

wildcard_captures_rest_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/files/*path">>, file_serve}
    ]),
    ?assertEqual(
        {ok, file_serve, #{<<"path">> => <<"a/b/c.txt">>}, undefined},
        livery_router:match(<<"GET">>, <<"/files/a/b/c.txt">>, R)
    ),
    ?assertEqual(
        {ok, file_serve, #{<<"path">> => <<"only">>}, undefined},
        livery_router:match(<<"GET">>, <<"/files/only">>, R)
    ),
    %% Zero-segment tail still matches when there are no more segments.
    ?assertMatch(
        {ok, file_serve, #{<<"path">> := <<>>}, _},
        livery_router:match(<<"GET">>, <<"/files">>, R)
    ).

method_filter_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/x">>, show},
        {<<"POST">>, <<"/x">>, create},
        {<<"QUERY">>, <<"/x">>, search}
    ]),
    ?assertMatch({ok, show, _, _}, livery_router:match(<<"GET">>, <<"/x">>, R)),
    ?assertMatch({ok, create, _, _}, livery_router:match(<<"POST">>, <<"/x">>, R)),
    ?assertMatch({ok, search, _, _}, livery_router:match(<<"QUERY">>, <<"/x">>, R)),
    ?assertEqual(
        {error, {method_not_allowed, [<<"GET">>, <<"POST">>, <<"QUERY">>]}},
        livery_router:match(<<"DELETE">>, <<"/x">>, R)
    ).

any_method_fallback_test() ->
    R = livery_router:compile([
        {'_', <<"/health">>, health}
    ]),
    ?assertMatch({ok, health, _, _}, livery_router:match(<<"GET">>, <<"/health">>, R)),
    ?assertMatch({ok, health, _, _}, livery_router:match(<<"POST">>, <<"/health">>, R)).

not_found_on_unknown_path_test() ->
    R = livery_router:compile([{<<"GET">>, <<"/a">>, a}]),
    ?assertEqual(
        {error, not_found},
        livery_router:match(<<"GET">>, <<"/b">>, R)
    ).

meta_is_returned_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/users/:id">>, user_show, #{doc => <<"Get a user">>}}
    ]),
    ?assertMatch(
        {ok, user_show, _, #{doc := <<"Get a user">>}},
        livery_router:match(<<"GET">>, <<"/users/7">>, R)
    ).

query_string_is_stripped_test() ->
    R = livery_router:compile([{<<"GET">>, <<"/q">>, q}]),
    ?assertMatch({ok, q, _, _}, livery_router:match(<<"GET">>, <<"/q?x=1&y=2">>, R)).

nested_params_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/users/:uid/posts/:pid">>, post_show}
    ]),
    ?assertEqual(
        {ok, post_show, #{<<"uid">> => <<"7">>, <<"pid">> => <<"11">>}, undefined},
        livery_router:match(<<"GET">>, <<"/users/7/posts/11">>, R)
    ).

wildcard_not_in_middle_test() ->
    ?assertError(
        {wildcard_must_be_last, <<"*rest">>},
        livery_router:compile([{<<"GET">>, <<"/a/*rest/b">>, x}])
    ).

conflicting_param_name_test() ->
    ?assertError(
        {conflicting_param, <<"id">>, <<"name">>},
        livery_router:compile([
            {<<"GET">>, <<"/u/:id">>, a},
            {<<"GET">>, <<"/u/:name">>, b}
        ])
    ).

%%====================================================================
%% Composition: routes/1, merge, nest, layer
%%====================================================================

routes_round_trip_test() ->
    Spec = [
        {<<"GET">>, <<"/">>, root},
        {<<"GET">>, <<"/users/:id">>, show},
        {<<"POST">>, <<"/users">>, create},
        {<<"GET">>, <<"/files/*path">>, files}
    ],
    R = livery_router:compile(Spec),
    %% routes/1 is the inverse of compile/1: the rebuilt router matches
    %% the same paths, patterns and bindings restored.
    R2 = livery_router:compile(livery_router:routes(R)),
    ?assertEqual({ok, root, #{}, undefined}, livery_router:match(<<"GET">>, <<"/">>, R2)),
    ?assertEqual(
        {ok, show, #{<<"id">> => <<"7">>}, undefined},
        livery_router:match(<<"GET">>, <<"/users/7">>, R2)
    ),
    ?assertEqual({ok, create, #{}, undefined}, livery_router:match(<<"POST">>, <<"/users">>, R2)),
    ?assertEqual(
        {ok, files, #{<<"path">> => <<"a/b.txt">>}, undefined},
        livery_router:match(<<"GET">>, <<"/files/a/b.txt">>, R2)
    ).

merge_combines_routers_test() ->
    A = livery_router:compile([{<<"GET">>, <<"/a">>, a}]),
    B = livery_router:compile([{<<"GET">>, <<"/b">>, b}]),
    R = livery_router:merge(A, B),
    ?assertEqual({ok, a, #{}, undefined}, livery_router:match(<<"GET">>, <<"/a">>, R)),
    ?assertEqual({ok, b, #{}, undefined}, livery_router:match(<<"GET">>, <<"/b">>, R)).

merge_later_router_wins_test() ->
    A = livery_router:compile([{<<"GET">>, <<"/x">>, first}]),
    B = livery_router:compile([{<<"GET">>, <<"/x">>, second}]),
    R = livery_router:merge(A, B),
    ?assertEqual({ok, second, #{}, undefined}, livery_router:match(<<"GET">>, <<"/x">>, R)).

merge_propagates_conflicts_test() ->
    A = livery_router:compile([{<<"GET">>, <<"/u/:id">>, a}]),
    B = livery_router:compile([{<<"GET">>, <<"/u/:name">>, b}]),
    ?assertError({conflicting_param, _, _}, livery_router:merge(A, B)).

nest_prefixes_subroutes_test() ->
    Sub = livery_router:compile([
        {<<"GET">>, <<"/mcp">>, mcp},
        {<<"GET">>, <<"/files/*path">>, files}
    ]),
    R = livery_router:nest(<<"/ai">>, Sub),
    ?assertEqual({ok, mcp, #{}, undefined}, livery_router:match(<<"GET">>, <<"/ai/mcp">>, R)),
    %% A wildcard sub-route stays last under the prefix.
    ?assertEqual(
        {ok, files, #{<<"path">> => <<"x/y">>}, undefined},
        livery_router:match(<<"GET">>, <<"/ai/files/x/y">>, R)
    ),
    ?assertEqual({error, not_found}, livery_router:match(<<"GET">>, <<"/mcp">>, R)).

nest_root_subroute_maps_to_prefix_test() ->
    Sub = livery_router:compile([{<<"GET">>, <<"/">>, home}]),
    R = livery_router:nest(<<"/app">>, Sub),
    ?assertEqual({ok, home, #{}, undefined}, livery_router:match(<<"GET">>, <<"/app">>, R)).

nest_into_parent_test() ->
    App = livery_router:compile([{<<"GET">>, <<"/">>, index}]),
    Sub = livery_router:compile([{<<"GET">>, <<"/mcp">>, mcp}]),
    R = livery_router:nest(<<"/ai">>, Sub, App),
    ?assertEqual({ok, index, #{}, undefined}, livery_router:match(<<"GET">>, <<"/">>, R)),
    ?assertEqual({ok, mcp, #{}, undefined}, livery_router:match(<<"GET">>, <<"/ai/mcp">>, R)).

mcp_router_merges_and_nests_test() ->
    App = livery_router:compile([{<<"GET">>, <<"/">>, index}]),
    %% Merge: MCP keeps its own /mcp path.
    Merged = livery_router:merge(App, livery_mcp:router()),
    {ok, Mcp, #{}, _} = livery_router:match(<<"POST">>, <<"/mcp">>, Merged),
    ?assert(is_function(Mcp, 1)),
    ?assertEqual({ok, index, #{}, undefined}, livery_router:match(<<"GET">>, <<"/">>, Merged)),
    %% Nest: MCP mounted under a prefix.
    Nested = livery_router:nest(<<"/ai">>, livery_mcp:router(), App),
    {ok, Mcp2, #{}, _} = livery_router:match(<<"GET">>, <<"/ai/mcp">>, Nested),
    ?assert(is_function(Mcp2, 1)).

layer_prepends_subtree_middleware_test() ->
    Mw = {auth, #{}},
    Sub = livery_router:compile([
        {<<"GET">>, <<"/x">>, x, #{middleware => [{log, undefined}]}},
        {<<"GET">>, <<"/y">>, y}
    ]),
    R = livery_router:layer([Mw], Sub),
    {ok, x, _, MetaX} = livery_router:match(<<"GET">>, <<"/x">>, R),
    {ok, y, _, MetaY} = livery_router:match(<<"GET">>, <<"/y">>, R),
    %% Stack is prepended, ahead of the route's own middleware.
    ?assertEqual([Mw, {log, undefined}], maps:get(middleware, MetaX)),
    ?assertEqual([Mw], maps:get(middleware, MetaY)).
