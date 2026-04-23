-module(livery_router_tests).

-include_lib("eunit/include/eunit.hrl").

static_match_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/">>, root},
        {<<"GET">>, <<"/users/new">>, users_new}
    ]),
    ?assertEqual({ok, root, #{}, undefined},
                 livery_router:match(<<"GET">>, <<"/">>, R)),
    ?assertEqual({ok, users_new, #{}, undefined},
                 livery_router:match(<<"GET">>, <<"/users/new">>, R)).

param_match_captures_binding_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/users/:id">>, user_show}
    ]),
    ?assertEqual({ok, user_show, #{<<"id">> => <<"42">>}, undefined},
                 livery_router:match(<<"GET">>, <<"/users/42">>, R)).

static_wins_over_param_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/users/new">>, users_new},
        {<<"GET">>, <<"/users/:id">>, user_show}
    ]),
    ?assertMatch({ok, users_new, _, _},
                 livery_router:match(<<"GET">>, <<"/users/new">>, R)),
    ?assertMatch({ok, user_show, #{<<"id">> := <<"42">>}, _},
                 livery_router:match(<<"GET">>, <<"/users/42">>, R)).

wildcard_captures_rest_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/files/*path">>, file_serve}
    ]),
    ?assertEqual({ok, file_serve, #{<<"path">> => <<"a/b/c.txt">>}, undefined},
                 livery_router:match(<<"GET">>, <<"/files/a/b/c.txt">>, R)),
    ?assertEqual({ok, file_serve, #{<<"path">> => <<"only">>}, undefined},
                 livery_router:match(<<"GET">>, <<"/files/only">>, R)),
    %% Zero-segment tail still matches when there are no more segments.
    ?assertMatch({ok, file_serve, #{<<"path">> := <<>>}, _},
                 livery_router:match(<<"GET">>, <<"/files">>, R)).

method_filter_test() ->
    R = livery_router:compile([
        {<<"GET">>,  <<"/x">>, show},
        {<<"POST">>, <<"/x">>, create}
    ]),
    ?assertMatch({ok, show, _, _}, livery_router:match(<<"GET">>, <<"/x">>, R)),
    ?assertMatch({ok, create, _, _}, livery_router:match(<<"POST">>, <<"/x">>, R)),
    ?assertEqual({error, {method_not_allowed, [<<"GET">>, <<"POST">>]}},
                 livery_router:match(<<"DELETE">>, <<"/x">>, R)).

any_method_fallback_test() ->
    R = livery_router:compile([
        {'_', <<"/health">>, health}
    ]),
    ?assertMatch({ok, health, _, _}, livery_router:match(<<"GET">>,  <<"/health">>, R)),
    ?assertMatch({ok, health, _, _}, livery_router:match(<<"POST">>, <<"/health">>, R)).

not_found_on_unknown_path_test() ->
    R = livery_router:compile([{<<"GET">>, <<"/a">>, a}]),
    ?assertEqual({error, not_found},
                 livery_router:match(<<"GET">>, <<"/b">>, R)).

meta_is_returned_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/users/:id">>, user_show, #{doc => <<"Get a user">>}}
    ]),
    ?assertMatch({ok, user_show, _, #{doc := <<"Get a user">>}},
                 livery_router:match(<<"GET">>, <<"/users/7">>, R)).

query_string_is_stripped_test() ->
    R = livery_router:compile([{<<"GET">>, <<"/q">>, q}]),
    ?assertMatch({ok, q, _, _}, livery_router:match(<<"GET">>, <<"/q?x=1&y=2">>, R)).

nested_params_test() ->
    R = livery_router:compile([
        {<<"GET">>, <<"/users/:uid/posts/:pid">>, post_show}
    ]),
    ?assertEqual({ok, post_show,
                  #{<<"uid">> => <<"7">>, <<"pid">> => <<"11">>},
                  undefined},
                 livery_router:match(<<"GET">>, <<"/users/7/posts/11">>, R)).

wildcard_not_in_middle_test() ->
    ?assertError({wildcard_must_be_last, <<"*rest">>},
                 livery_router:compile([{<<"GET">>, <<"/a/*rest/b">>, x}])).

conflicting_param_name_test() ->
    ?assertError({conflicting_param, <<"id">>, <<"name">>},
                 livery_router:compile([
                    {<<"GET">>, <<"/u/:id">>, a},
                    {<<"GET">>, <<"/u/:name">>, b}
                 ])).
