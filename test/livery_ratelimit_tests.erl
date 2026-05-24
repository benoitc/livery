-module(livery_ratelimit_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%% The store is a supervised gen_server, so the livery application must be
%% running. Start it once for the whole module.
ratelimit_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"burst then shed", fun burst/0},
        {"refill admits again", fun refill/0},
        {"no key passes through", fun no_key/0},
        {"allow + 429 headers", fun headers/0},
        {"keys are isolated", fun isolation/0},
        {"custom key fun", fun custom_key/0},
        {"headers can be disabled", fun headers_off/0},
        {"custom status and body", fun custom_status/0},
        {"CAS under contention", fun contention/0},
        {"cleanup keeps an exhausted key", fun cleanup_keeps_exhausted/0},
        {"cleanup removes a full key", fun cleanup_removes_full/0}
    ]}.

setup() ->
    {ok, _} = application:ensure_all_started(livery),
    ok.

cleanup(_) ->
    %% Stop the app we started so other test modules (which start
    %% livery_req_sup standalone) are not affected by a running livery.
    _ = application:stop(livery),
    ok.

%%====================================================================
%% Cases
%%====================================================================

burst() ->
    L = livery_ratelimit:limiter(3, 0),
    T = <<"burst">>,
    ?assertEqual(200, status(run(L, T))),
    ?assertEqual(200, status(run(L, T))),
    ?assertEqual(200, status(run(L, T))),
    ?assertEqual(429, status(run(L, T))).

refill() ->
    L = livery_ratelimit:limiter(1, 100),
    T = <<"refill">>,
    ?assertEqual(200, status(run(L, T))),
    ?assertEqual(429, status(run(L, T))),
    timer:sleep(20),
    ?assertEqual(200, status(run(L, T))).

no_key() ->
    L = livery_ratelimit:limiter(0, 0),
    Cap = livery_test_adapter:run(
        [{livery_ratelimit, L}],
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        #{}
    ),
    ?assertEqual(200, status(Cap)).

headers() ->
    L = livery_ratelimit:limiter(5, 10),
    Cap = run(L, <<"hdr">>),
    ?assertEqual(200, status(Cap)),
    ?assertEqual(<<"5">>, hdr(<<"ratelimit-limit">>, Cap)),
    ?assertEqual(<<"4">>, hdr(<<"ratelimit-remaining">>, Cap)),
    L2 = livery_ratelimit:limiter(1, 10),
    ?assertEqual(200, status(run(L2, <<"hdr2">>))),
    Denied = run(L2, <<"hdr2">>),
    ?assertEqual(429, status(Denied)),
    ?assert(is_binary(hdr(<<"retry-after">>, Denied))).

isolation() ->
    L = livery_ratelimit:limiter(1, 0),
    ?assertEqual(200, status(run(L, <<"key-a">>))),
    ?assertEqual(429, status(run(L, <<"key-a">>))),
    ?assertEqual(200, status(run(L, <<"key-b">>))).

custom_key() ->
    L = livery_ratelimit:limiter(1, 0, #{key => fun(_R) -> <<"fixed">> end}),
    H = fun(_R) -> livery_resp:text(200, <<"ok">>) end,
    %% No Authorization header, but the custom key always returns "fixed".
    ?assertEqual(
        200,
        livery_test_adapter:status(
            livery_test_adapter:run([{livery_ratelimit, L}], H, #{})
        )
    ),
    ?assertEqual(
        429,
        livery_test_adapter:status(
            livery_test_adapter:run([{livery_ratelimit, L}], H, #{})
        )
    ).

headers_off() ->
    L = livery_ratelimit:limiter(1, 0, #{headers => false}),
    Allowed = run(L, <<"off">>),
    ?assertEqual(200, status(Allowed)),
    ?assertEqual(undefined, hdr(<<"ratelimit-limit">>, Allowed)),
    Denied = run(L, <<"off">>),
    ?assertEqual(429, status(Denied)),
    ?assertEqual(undefined, hdr(<<"retry-after">>, Denied)).

custom_status() ->
    L = livery_ratelimit:limiter(0, 0, #{status => 503, body => <<"nope">>}),
    Cap = run(L, <<"cust">>),
    ?assertEqual(503, status(Cap)),
    ?assertEqual(<<"nope">>, livery_test_adapter:body(Cap)).

contention() ->
    L = livery_ratelimit:limiter(5, 0),
    T = <<"cas">>,
    Self = self(),
    N = 20,
    [
        spawn(fun() -> Self ! {result, status(run(L, T))} end)
     || _ <- lists:seq(1, N)
    ],
    Statuses = [
        receive
            {result, S} -> S
        after 5000 -> error(timeout)
        end
     || _ <- lists:seq(1, N)
    ],
    ?assertEqual(5, length([ok || 200 <- Statuses])),
    ?assertEqual(15, length([ok || 429 <- Statuses])).

cleanup_keeps_exhausted() ->
    L = livery_ratelimit:limiter(1, 0),
    T = <<"hot">>,
    ?assertEqual(200, status(run(L, T))),
    ?assertEqual(429, status(run(L, T))),
    _ = livery_ratelimit_store:sweep(),
    ?assertEqual(429, status(run(L, T))).

cleanup_removes_full() ->
    L = livery_ratelimit:limiter(1, 1000),
    Name = maps:get(name, L),
    F = <<"fullkey">>,
    ?assertEqual(200, status(run(L, F))),
    timer:sleep(10),
    _ = livery_ratelimit_store:sweep(),
    ?assertEqual(
        [], ets:lookup(livery_ratelimit, {Name, crypto:hash(sha256, F)})
    ).

%%====================================================================
%% Helpers
%%====================================================================

run(Limiter, Token) ->
    livery_test_adapter:run(
        [{livery_ratelimit, Limiter}],
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        #{headers => [{<<"authorization">>, <<"Bearer ", Token/binary>>}]}
    ).

status(Cap) ->
    livery_test_adapter:status(Cap).

hdr(Name, Cap) ->
    livery_test_adapter:header(Name, Cap).
