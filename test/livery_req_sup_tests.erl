%% @doc The per-request supervisor caps concurrent workers so a flood
%% cannot exhaust the process table.
-module(livery_req_sup_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

overload_rejects_past_cap_test() ->
    {ok, _} = application:ensure_all_started(livery),
    Old = application:get_env(livery, max_concurrent_requests, 10000),
    application:set_env(livery, max_concurrent_requests, 1),
    try
        Test = self(),
        Handler = fun(_Req) ->
            Test ! ready,
            receive
                stop -> ok
            end
        end,
        Args = #{
            adapter => livery_test_adapter,
            stream => undefined,
            req => livery_req:new(#{method => <<"GET">>, path => <<"/">>}),
            stack => [],
            handler => Handler
        },
        {ok, W1} = livery_req_sup:start_request(Args),
        receive
            ready -> ok
        after 5000 -> error(worker_never_ran)
        end,
        ?assertEqual({error, overload}, livery_req_sup:start_request(Args)),
        exit(W1, kill)
    after
        application:set_env(livery, max_concurrent_requests, Old)
    end.
