-module(livery_req_proc_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Direct spawn via start_link
%%====================================================================

spawn_runs_handler_and_emits_response_test() ->
    Tab = livery_test_adapter:start(),
    try
        Stream = livery_test_adapter:new_stream(Tab),
        Req = livery_req:new(#{protocol => h1, method => <<"GET">>, path => <<"/">>}),
        {ok, Pid} = livery_req_proc:start_link(#{
            adapter => livery_test_adapter,
            stream => Stream,
            req => Req,
            stack => [],
            handler => fun(_R) -> livery_resp:text(200, <<"hello">>) end
        }),
        wait_for_exit(Pid, 1000),
        Cap = livery_test_adapter:capture(Stream),
        ?assertEqual(200, livery_test_adapter:status(Cap)),
        ?assertEqual(<<"hello">>, livery_test_adapter:body(Cap))
    after
        livery_test_adapter:stop(Tab)
    end.

handler_crash_emits_500_test() ->
    Tab = livery_test_adapter:start(),
    process_flag(trap_exit, true),
    try
        Stream = livery_test_adapter:new_stream(Tab),
        Req = livery_req:new(#{protocol => h1, method => <<"GET">>, path => <<"/">>}),
        {ok, Pid} = livery_req_proc:start_link(#{
            adapter => livery_test_adapter,
            stream => Stream,
            req => Req,
            stack => [],
            handler => fun(_R) -> error(boom) end
        }),
        wait_for_exit(Pid, 1000),
        Cap = livery_test_adapter:capture(Stream),
        ?assertEqual(500, livery_test_adapter:status(Cap)),
        ?assertEqual(
            <<"internal server error">>,
            livery_test_adapter:body(Cap)
        )
    after
        livery_test_adapter:stop(Tab),
        process_flag(trap_exit, false)
    end.

started_at_set_when_absent_test() ->
    Tab = livery_test_adapter:start(),
    Self = self(),
    try
        Stream = livery_test_adapter:new_stream(Tab),
        Req = livery_req:new(#{protocol => h1, method => <<"GET">>, path => <<"/">>}),
        Handler = fun(R) ->
            Self ! {started_at, livery_req:started_at(R)},
            livery_resp:text(200, <<>>)
        end,
        {ok, _} = livery_req_proc:start_link(#{
            adapter => livery_test_adapter,
            stream => Stream,
            req => Req,
            stack => [],
            handler => Handler
        }),
        receive
            {started_at, T} ->
                ?assert(is_integer(T))
        after 1000 ->
            ?assert(false)
        end
    after
        livery_test_adapter:stop(Tab)
    end.

%%====================================================================
%% Via livery_req_sup
%%====================================================================

start_request_through_supervisor_test() ->
    {ok, SupPid} = livery_req_sup:start_link(),
    Tab = livery_test_adapter:start(),
    try
        Stream = livery_test_adapter:new_stream(Tab),
        Req = livery_req:new(#{protocol => h1, method => <<"GET">>, path => <<"/sup">>}),
        {ok, Pid} = livery_req_sup:start_request(#{
            adapter => livery_test_adapter,
            stream => Stream,
            req => Req,
            stack => [],
            handler => fun(_R) -> livery_resp:text(201, <<"made it">>) end
        }),
        wait_for_exit(Pid, 1000),
        Cap = livery_test_adapter:capture(Stream),
        ?assertEqual(201, livery_test_adapter:status(Cap)),
        ?assertEqual(<<"made it">>, livery_test_adapter:body(Cap))
    after
        livery_test_adapter:stop(Tab),
        unlink(SupPid),
        exit(SupPid, shutdown),
        wait_for_exit(SupPid, 1000)
    end.

%%====================================================================
%% Helpers
%%====================================================================

wait_for_exit(Pid, Timeout) ->
    MRef = erlang:monitor(process, Pid),
    receive
        {'DOWN', MRef, process, Pid, _} -> ok
    after Timeout ->
        erlang:demonitor(MRef, [flush]),
        ?assert(false)
    end.
