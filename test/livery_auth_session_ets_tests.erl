%% @doc The default session store: record, check, revoke, expire, cap.
-module(livery_auth_session_ets_tests).

-include_lib("eunit/include/eunit.hrl").

-define(S, livery_auth_session_ets).

store_test_() ->
    {setup,
        fun() ->
            {ok, Apps} = application:ensure_all_started(livery),
            Apps
        end,
        fun(Apps) -> [application:stop(A) || A <- lists:reverse(Apps)] end, [
            {"a recorded session is valid", fun recorded_is_valid/0},
            {"an unknown session is invalid", fun unknown_is_invalid/0},
            {"revoke ends one session", fun revoke_one/0},
            {"revoke_user ends that user's sessions only", fun revoke_user/0},
            {"revoke by provider session", fun revoke_provider_session/0},
            {"an expired session is invalid and swept", fun expired/0},
            {"a full store refuses new sessions", fun full/0}
        ]}.

entry(Sid, Iss, Sub, PSid, ExpiresAt) ->
    #{sid => Sid, iss => Iss, sub => Sub, provider_sid => PSid, expires_at => ExpiresAt}.

later() -> os:system_time(second) + 3600.

recorded_is_valid() ->
    ok = ?S:record(undefined, entry(<<"s1">>, <<"iss">>, <<"alice">>, undefined, later())),
    ?assertEqual(valid, ?S:check(undefined, <<"s1">>)).

unknown_is_invalid() ->
    ?assertEqual(invalid, ?S:check(undefined, <<"nope">>)).

revoke_one() ->
    ok = ?S:record(undefined, entry(<<"r1">>, <<"iss">>, <<"bob">>, undefined, later())),
    ok = ?S:record(undefined, entry(<<"r2">>, <<"iss">>, <<"bob">>, undefined, later())),
    ok = ?S:revoke(undefined, <<"r1">>),
    ?assertEqual(invalid, ?S:check(undefined, <<"r1">>)),
    ?assertEqual(valid, ?S:check(undefined, <<"r2">>)),
    ?assertEqual(ok, ?S:revoke(undefined, <<"r1">>)).

revoke_user() ->
    ok = ?S:record(undefined, entry(<<"u1">>, <<"iss">>, <<"carol">>, undefined, later())),
    ok = ?S:record(undefined, entry(<<"u2">>, <<"iss">>, <<"carol">>, undefined, later())),
    ok = ?S:record(undefined, entry(<<"u3">>, <<"other">>, <<"carol">>, undefined, later())),
    ok = ?S:record(undefined, entry(<<"u4">>, <<"iss">>, <<"dave">>, undefined, later())),
    ok = ?S:revoke_user(undefined, <<"iss">>, <<"carol">>),
    ?assertEqual(
        [invalid, invalid, valid, valid],
        [?S:check(undefined, S) || S <- [<<"u1">>, <<"u2">>, <<"u3">>, <<"u4">>]]
    ).

revoke_provider_session() ->
    ok = ?S:record(undefined, entry(<<"p1">>, <<"iss">>, <<"erin">>, <<"op-1">>, later())),
    ok = ?S:record(undefined, entry(<<"p2">>, <<"iss">>, <<"erin">>, <<"op-2">>, later())),
    ok = ?S:record(undefined, entry(<<"p3">>, <<"other">>, <<"erin">>, <<"op-1">>, later())),
    ok = ?S:revoke_provider_session(undefined, <<"iss">>, <<"op-1">>),
    ?assertEqual(
        [invalid, valid, valid],
        [?S:check(undefined, S) || S <- [<<"p1">>, <<"p2">>, <<"p3">>]]
    ).

expired() ->
    Now = os:system_time(second),
    ok = ?S:record(undefined, entry(<<"e1">>, <<"iss">>, <<"frank">>, undefined, Now)),
    ?assertEqual(invalid, ?S:check(undefined, <<"e1">>)),
    ?assert(?S:sweep() >= 1),
    ?assertEqual([], ets:lookup(livery_auth_sessions, <<"e1">>)).

full() ->
    Size = ets:info(livery_auth_sessions, size),
    application:set_env(livery, session_max, Size),
    try
        ?assertEqual(
            {error, full},
            ?S:record(undefined, entry(<<"f1">>, <<"iss">>, <<"gina">>, undefined, later()))
        )
    after
        application:unset_env(livery, session_max)
    end.
