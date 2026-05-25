-module(livery_health_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

live_test() ->
    Cap = run(livery_health:live()),
    ?assertEqual(200, status(Cap)),
    ?assertEqual(<<"{\"status\":\"ok\"}">>, body(Cap)).

ready_empty_test() ->
    Cap = run(livery_health:ready([])),
    ?assertEqual(200, status(Cap)).

ready_all_pass_test() ->
    Checks = [{<<"a">>, fun() -> ok end}, {<<"b">>, fun() -> ok end}],
    Cap = run(livery_health:ready(Checks)),
    ?assertEqual(200, status(Cap)).

ready_one_fails_test() ->
    Checks = [
        {<<"a">>, fun() -> ok end},
        {<<"db">>, fun() -> {error, down} end}
    ],
    Cap = run(livery_health:ready(Checks)),
    ?assertEqual(503, status(Cap)),
    Decoded = json:decode(body(Cap)),
    ?assertEqual(<<"unavailable">>, maps:get(<<"status">>, Decoded)),
    ?assertEqual([<<"db">>], maps:get(<<"failed">>, Decoded)).

ready_check_raises_test() ->
    Cap = run(livery_health:ready([{<<"boom">>, fun() -> error(boom) end}])),
    ?assertEqual(503, status(Cap)),
    ?assertEqual([<<"boom">>], maps:get(<<"failed">>, json:decode(body(Cap)))).

ready_non_ok_return_test() ->
    Cap = run(livery_health:ready([{<<"x">>, fun() -> not_ok end}])),
    ?assertEqual(503, status(Cap)).

%%====================================================================
%% Helpers
%%====================================================================

run(Handler) ->
    livery_test_adapter:run([], Handler, #{method => <<"GET">>}).

status(Cap) -> livery_test_adapter:status(Cap).
body(Cap) -> livery_test_adapter:body(Cap).
