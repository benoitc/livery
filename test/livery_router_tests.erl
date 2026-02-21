%% @doc Unit tests for HTTP router.
-module(livery_router_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% Basic routing tests
%% ===================================================================

compile_empty_test() ->
    Router = livery_router:compile([]),
    ?assertEqual({error, not_found}, livery_router:match(Router, <<"GET">>, <<"/">>)).

match_root_test() ->
    Routes = [{get, "/", home_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, Handler, Opts, Bindings} = livery_router:match(Router, <<"GET">>, <<"/">>),
    ?assertEqual(home_handler, Handler),
    ?assertEqual([], Opts),
    ?assertEqual(#{}, Bindings).

match_simple_path_test() ->
    Routes = [{get, "/users", users_handler, #{}}],
    Router = livery_router:compile(Routes),
    {ok, Handler, Opts, _} = livery_router:match(Router, <<"GET">>, <<"/users">>),
    ?assertEqual(users_handler, Handler),
    ?assertEqual(#{}, Opts).

match_nested_path_test() ->
    Routes = [{get, "/api/v1/users", users_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, _} = livery_router:match(Router, <<"GET">>, <<"/api/v1/users">>),
    ?assertEqual(users_handler, Handler).

match_not_found_test() ->
    Routes = [{get, "/users", users_handler, []}],
    Router = livery_router:compile(Routes),
    ?assertEqual({error, not_found}, livery_router:match(Router, <<"GET">>, <<"/posts">>)).

%% ===================================================================
%% Method routing tests
%% ===================================================================

match_method_get_test() ->
    Routes = [
        {get, "/users", get_handler, []},
        {post, "/users", post_handler, []}
    ],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, _} = livery_router:match(Router, <<"GET">>, <<"/users">>),
    ?assertEqual(get_handler, Handler).

match_method_post_test() ->
    Routes = [
        {get, "/users", get_handler, []},
        {post, "/users", post_handler, []}
    ],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, _} = livery_router:match(Router, <<"POST">>, <<"/users">>),
    ?assertEqual(post_handler, Handler).

match_method_put_test() ->
    Routes = [{put, "/users/:id", update_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, _} = livery_router:match(Router, <<"PUT">>, <<"/users/123">>),
    ?assertEqual(update_handler, Handler).

match_method_delete_test() ->
    Routes = [{delete, "/users/:id", delete_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, _} = livery_router:match(Router, <<"DELETE">>, <<"/users/123">>),
    ?assertEqual(delete_handler, Handler).

match_wildcard_method_test() ->
    Routes = [{'_', "/health", health_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, _} = livery_router:match(Router, <<"GET">>, <<"/health">>),
    ?assertEqual(health_handler, Handler),
    {ok, Handler, _, _} = livery_router:match(Router, <<"POST">>, <<"/health">>),
    ?assertEqual(health_handler, Handler).

%% ===================================================================
%% Parameter binding tests
%% ===================================================================

match_single_param_test() ->
    Routes = [{get, "/users/:id", user_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, Bindings} = livery_router:match(Router, <<"GET">>, <<"/users/123">>),
    ?assertEqual(user_handler, Handler),
    ?assertEqual(#{<<"id">> => <<"123">>}, Bindings).

match_multiple_params_test() ->
    Routes = [{get, "/users/:user_id/posts/:post_id", post_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, _, _, Bindings} = livery_router:match(Router, <<"GET">>, <<"/users/42/posts/7">>),
    ?assertEqual(#{<<"user_id">> => <<"42">>, <<"post_id">> => <<"7">>}, Bindings).

match_param_with_static_test() ->
    Routes = [
        {get, "/users/new", new_user_handler, []},
        {get, "/users/:id", user_handler, []}
    ],
    Router = livery_router:compile(Routes),

    %% Static should match first
    {ok, Handler1, _, _} = livery_router:match(Router, <<"GET">>, <<"/users/new">>),
    ?assertEqual(new_user_handler, Handler1),

    %% Then param
    {ok, Handler2, _, Bindings} = livery_router:match(Router, <<"GET">>, <<"/users/123">>),
    ?assertEqual(user_handler, Handler2),
    ?assertEqual(#{<<"id">> => <<"123">>}, Bindings).

%% ===================================================================
%% Wildcard segment tests
%% ===================================================================

match_wildcard_test() ->
    Routes = [{get, "/files/*path", files_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, Bindings} = livery_router:match(Router, <<"GET">>, <<"/files/images/logo.png">>),
    ?assertEqual(files_handler, Handler),
    ?assertEqual(#{<<"path">> => <<"images/logo.png">>}, Bindings).

match_wildcard_single_segment_test() ->
    Routes = [{get, "/api/*path", api_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, Bindings} = livery_router:match(Router, <<"GET">>, <<"/api/users">>),
    ?assertEqual(api_handler, Handler),
    ?assertEqual(#{<<"path">> => <<"users">>}, Bindings).

match_wildcard_empty_test() ->
    Routes = [{get, "/docs/*path", docs_handler, []}],
    Router = livery_router:compile(Routes),
    %% Wildcard with no segments after prefix
    {error, not_found} = livery_router:match(Router, <<"GET">>, <<"/docs">>).

%% ===================================================================
%% Path edge cases
%% ===================================================================

match_trailing_slash_test() ->
    Routes = [{get, "/users", users_handler, []}],
    Router = livery_router:compile(Routes),
    %% With trailing slash should still match
    {ok, Handler, _, _} = livery_router:match(Router, <<"GET">>, <<"/users/">>),
    ?assertEqual(users_handler, Handler).

match_double_slash_test() ->
    Routes = [{get, "/api/users", users_handler, []}],
    Router = livery_router:compile(Routes),
    %% Double slashes should be normalized
    {ok, Handler, _, _} = livery_router:match(Router, <<"GET">>, <<"/api//users">>),
    ?assertEqual(users_handler, Handler).

match_no_leading_slash_test() ->
    Routes = [{get, "users", users_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, _} = livery_router:match(Router, <<"GET">>, <<"/users">>),
    ?assertEqual(users_handler, Handler).

match_with_query_string_test() ->
    Routes = [{get, "/search", search_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, _} = livery_router:match(Router, <<"GET">>, <<"/search?q=test">>),
    ?assertEqual(search_handler, Handler).

%% ===================================================================
%% Dynamic route modification tests
%% ===================================================================

add_route_test() ->
    Router0 = livery_router:compile([]),
    Router1 = livery_router:add_route({get, "/new", new_handler, []}, Router0),
    {ok, Handler, _, _} = livery_router:match(Router1, <<"GET">>, <<"/new">>),
    ?assertEqual(new_handler, Handler).

remove_route_test() ->
    Routes = [{get, "/remove", remove_handler, []}],
    Router0 = livery_router:compile(Routes),
    Router1 = livery_router:remove_route({get, "/remove"}, Router0),
    ?assertEqual({error, not_found}, livery_router:match(Router1, <<"GET">>, <<"/remove">>)).

%% ===================================================================
%% Multiple routes tests
%% ===================================================================

multiple_routes_test() ->
    Routes = [
        {get, "/", home_handler, []},
        {get, "/users", users_list_handler, []},
        {get, "/users/:id", user_handler, []},
        {post, "/users", user_create_handler, []},
        {put, "/users/:id", user_update_handler, []},
        {delete, "/users/:id", user_delete_handler, []},
        {get, "/posts", posts_handler, []},
        {get, "/posts/:id/comments", comments_handler, []}
    ],
    Router = livery_router:compile(Routes),

    {ok, H1, _, _} = livery_router:match(Router, <<"GET">>, <<"/">>),
    ?assertEqual(home_handler, H1),

    {ok, H2, _, _} = livery_router:match(Router, <<"GET">>, <<"/users">>),
    ?assertEqual(users_list_handler, H2),

    {ok, H3, _, B3} = livery_router:match(Router, <<"GET">>, <<"/users/42">>),
    ?assertEqual(user_handler, H3),
    ?assertEqual(#{<<"id">> => <<"42">>}, B3),

    {ok, H4, _, _} = livery_router:match(Router, <<"POST">>, <<"/users">>),
    ?assertEqual(user_create_handler, H4),

    {ok, H5, _, _} = livery_router:match(Router, <<"PUT">>, <<"/users/42">>),
    ?assertEqual(user_update_handler, H5),

    {ok, H6, _, _} = livery_router:match(Router, <<"DELETE">>, <<"/users/42">>),
    ?assertEqual(user_delete_handler, H6),

    {ok, H7, _, B7} = livery_router:match(Router, <<"GET">>, <<"/posts/5/comments">>),
    ?assertEqual(comments_handler, H7),
    ?assertEqual(#{<<"id">> => <<"5">>}, B7).

%% ===================================================================
%% String path tests
%% ===================================================================

string_path_test() ->
    Routes = [{get, "/users", users_handler, []}],
    Router = livery_router:compile(Routes),
    {ok, Handler, _, _} = livery_router:match(Router, <<"GET">>, <<"/users">>),
    ?assertEqual(users_handler, Handler).

%% ===================================================================
%% Handler options tests
%% ===================================================================

handler_opts_test() ->
    Opts = #{auth => required, role => admin},
    Routes = [{get, "/admin", admin_handler, Opts}],
    Router = livery_router:compile(Routes),
    {ok, Handler, RetOpts, _} = livery_router:match(Router, <<"GET">>, <<"/admin">>),
    ?assertEqual(admin_handler, Handler),
    ?assertEqual(Opts, RetOpts).
