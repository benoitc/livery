%% @doc Unit tests for middleware chain.
-module(livery_middleware_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% Basic middleware tests
%% ===================================================================

compile_empty_test() ->
    Chain = livery_middleware:compile([]),
    Handler = fun(Req) -> {200, [], <<"OK">>, Req} end,
    Result = livery_middleware:execute(Chain, test_req, Handler),
    ?assertEqual({200, [], <<"OK">>, test_req}, Result).

single_middleware_test() ->
    Middleware = fun(Req, Next) ->
        {Status, Headers, Body, Req1} = Next(Req),
        {Status, [{<<"x-middleware">>, <<"applied">>} | Headers], Body, Req1}
    end,
    Chain = livery_middleware:compile([Middleware]),
    Handler = fun(Req) -> {200, [], <<"OK">>, Req} end,
    {Status, Headers, Body, _} = livery_middleware:execute(Chain, test_req, Handler),
    ?assertEqual(200, Status),
    ?assertEqual(<<"OK">>, Body),
    ?assert(lists:member({<<"x-middleware">>, <<"applied">>}, Headers)).

multiple_middleware_test() ->
    M1 = fun(Req, Next) ->
        {Status, Headers, Body, Req1} = Next(Req),
        {Status, [{<<"x-m1">>, <<"1">>} | Headers], Body, Req1}
    end,
    M2 = fun(Req, Next) ->
        {Status, Headers, Body, Req1} = Next(Req),
        {Status, [{<<"x-m2">>, <<"2">>} | Headers], Body, Req1}
    end,
    Chain = livery_middleware:compile([M1, M2]),
    Handler = fun(Req) -> {200, [], <<"OK">>, Req} end,
    {_, Headers, _, _} = livery_middleware:execute(Chain, test_req, Handler),
    %% Both middleware headers should be present
    ?assert(lists:member({<<"x-m1">>, <<"1">>}, Headers)),
    ?assert(lists:member({<<"x-m2">>, <<"2">>}, Headers)).

%% ===================================================================
%% Middleware order tests
%% ===================================================================

middleware_order_test() ->
    %% Middleware should execute in order, with first being outermost
    Log = fun() -> ets:new(log, [public, named_table, ordered_set]) end,
    Log(),
    try
        M1 = fun(Req, Next) ->
            ets:insert(log, {1, m1_before}),
            Result = Next(Req),
            ets:insert(log, {4, m1_after}),
            Result
        end,
        M2 = fun(Req, Next) ->
            ets:insert(log, {2, m2_before}),
            Result = Next(Req),
            ets:insert(log, {3, m2_after}),
            Result
        end,
        Chain = livery_middleware:compile([M1, M2]),
        Handler = fun(Req) -> {200, [], <<"OK">>, Req} end,
        livery_middleware:execute(Chain, test_req, Handler),

        Events = ets:tab2list(log),
        ?assertEqual([{1, m1_before}, {2, m2_before}, {3, m2_after}, {4, m1_after}], Events)
    after
        ets:delete(log)
    end.

%% ===================================================================
%% Short-circuit tests
%% ===================================================================

short_circuit_middleware_test() ->
    %% Auth middleware that can short-circuit
    AuthMiddleware = fun(Req, Next) ->
        case Req of
            {authorized, R} -> Next(R);
            _ -> {401, [], <<"Unauthorized">>, Req}
        end
    end,
    Chain = livery_middleware:compile([AuthMiddleware]),
    Handler = fun(Req) -> {200, [], <<"OK">>, Req} end,

    %% Unauthorized request
    {Status1, _, Body1, _} = livery_middleware:execute(Chain, unauthorized, Handler),
    ?assertEqual(401, Status1),
    ?assertEqual(<<"Unauthorized">>, Body1),

    %% Authorized request
    {Status2, _, Body2, _} = livery_middleware:execute(Chain, {authorized, test_req}, Handler),
    ?assertEqual(200, Status2),
    ?assertEqual(<<"OK">>, Body2).

%% ===================================================================
%% Request transformation tests
%% ===================================================================

transform_request_test() ->
    %% Middleware that transforms the request
    TransformMiddleware = fun(Req, Next) ->
        Next({transformed, Req})
    end,
    Chain = livery_middleware:compile([TransformMiddleware]),
    Handler = fun(Req) ->
        case Req of
            {transformed, _} -> {200, [], <<"transformed">>, Req};
            _ -> {200, [], <<"original">>, Req}
        end
    end,
    {_, _, Body, _} = livery_middleware:execute(Chain, original_req, Handler),
    ?assertEqual(<<"transformed">>, Body).

%% ===================================================================
%% Response transformation tests
%% ===================================================================

transform_response_test() ->
    %% Middleware that transforms the response
    TransformMiddleware = fun(Req, Next) ->
        {Status, Headers, _Body, Req1} = Next(Req),
        {Status, Headers, <<"transformed">>, Req1}
    end,
    Chain = livery_middleware:compile([TransformMiddleware]),
    Handler = fun(Req) -> {200, [], <<"original">>, Req} end,
    {_, _, Body, _} = livery_middleware:execute(Chain, test_req, Handler),
    ?assertEqual(<<"transformed">>, Body).

%% ===================================================================
%% Before middleware helper tests
%% ===================================================================

before_middleware_success_test() ->
    BeforeFun = fun(Req) -> {ok, {enriched, Req}} end,
    Middleware = livery_middleware:before(BeforeFun),
    Chain = livery_middleware:compile([Middleware]),
    Handler = fun({enriched, _} = Req) -> {200, [], <<"enriched">>, Req};
                 (Req) -> {200, [], <<"not_enriched">>, Req}
             end,
    {_, _, Body, _} = livery_middleware:execute(Chain, test_req, Handler),
    ?assertEqual(<<"enriched">>, Body).

before_middleware_error_test() ->
    BeforeFun = fun(_Req) -> {error, {403, [], <<"Forbidden">>}} end,
    Middleware = livery_middleware:before(BeforeFun),
    Chain = livery_middleware:compile([Middleware]),
    Handler = fun(Req) -> {200, [], <<"OK">>, Req} end,
    {Status, _, Body, _} = livery_middleware:execute(Chain, test_req, Handler),
    ?assertEqual(403, Status),
    ?assertEqual(<<"Forbidden">>, Body).

%% ===================================================================
%% After middleware helper tests
%% ===================================================================

after_response_middleware_test() ->
    AfterFun = fun({Status, Headers, Body, Req}) ->
        {Status, [{<<"x-after">>, <<"applied">>} | Headers], Body, Req}
    end,
    Middleware = livery_middleware:after_response(AfterFun),
    Chain = livery_middleware:compile([Middleware]),
    Handler = fun(Req) -> {200, [], <<"OK">>, Req} end,
    {_, Headers, _, _} = livery_middleware:execute(Chain, test_req, Handler),
    ?assert(lists:member({<<"x-after">>, <<"applied">>}, Headers)).

%% ===================================================================
%% Wrap middleware helper tests
%% ===================================================================

wrap_middleware_test() ->
    %% Wrap middleware for timing or error handling
    WrapFun = fun(InnerFun) ->
        try
            InnerFun()
        catch
            _:_ -> {500, [], <<"Error">>, undefined}
        end
    end,
    Middleware = livery_middleware:wrap(WrapFun),
    Chain = livery_middleware:compile([Middleware]),

    %% Normal handler
    Handler1 = fun(Req) -> {200, [], <<"OK">>, Req} end,
    {Status1, _, _, _} = livery_middleware:execute(Chain, test_req, Handler1),
    ?assertEqual(200, Status1),

    %% Crashing handler
    Handler2 = fun(_Req) -> error(crash) end,
    {Status2, _, Body2, _} = livery_middleware:execute(Chain, test_req, Handler2),
    ?assertEqual(500, Status2),
    ?assertEqual(<<"Error">>, Body2).

%% ===================================================================
%% Complex middleware chain tests
%% ===================================================================

complex_chain_test() ->
    %% Build a realistic middleware chain
    LoggingMiddleware = fun(Req, Next) ->
        {Status, Headers, Body, Req1} = Next(Req),
        {Status, [{<<"x-logged">>, <<"true">>} | Headers], Body, Req1}
    end,
    AuthMiddleware = fun(Req, Next) ->
        case Req of
            {auth, _, _} = R -> Next(R);
            R -> Next({auth, anonymous, R})
        end
    end,
    CorsMiddleware = fun(Req, Next) ->
        {Status, Headers, Body, Req1} = Next(Req),
        CorsHeaders = [{<<"access-control-allow-origin">>, <<"*">>}],
        {Status, CorsHeaders ++ Headers, Body, Req1}
    end,

    Chain = livery_middleware:compile([LoggingMiddleware, AuthMiddleware, CorsMiddleware]),
    Handler = fun({auth, User, _Req} = R) ->
        Body = iolist_to_binary(["User: ", atom_to_list(User)]),
        {200, [], Body, R}
    end,

    {Status, Headers, Body, _} = livery_middleware:execute(Chain, original_req, Handler),
    ?assertEqual(200, Status),
    ?assertEqual(<<"User: anonymous">>, Body),
    ?assert(lists:member({<<"x-logged">>, <<"true">>}, Headers)),
    ?assert(lists:member({<<"access-control-allow-origin">>, <<"*">>}, Headers)).

%% ===================================================================
%% Middleware with state tests
%% ===================================================================

stateful_middleware_test() ->
    %% Middleware can pass state through request transformation
    Counter = fun() -> ets:new(counter, [public, named_table, set]) end,
    Counter(),
    ets:insert(counter, {count, 0}),
    try
        CountingMiddleware = fun(Req, Next) ->
            [{count, N}] = ets:lookup(counter, count),
            ets:insert(counter, {count, N + 1}),
            Next(Req)
        end,
        Chain = livery_middleware:compile([CountingMiddleware]),
        Handler = fun(Req) -> {200, [], <<"OK">>, Req} end,

        livery_middleware:execute(Chain, req1, Handler),
        livery_middleware:execute(Chain, req2, Handler),
        livery_middleware:execute(Chain, req3, Handler),

        [{count, Count}] = ets:lookup(counter, count),
        ?assertEqual(3, Count)
    after
        ets:delete(counter)
    end.
