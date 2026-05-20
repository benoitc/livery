-module(livery_drain_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Fixtures
%%====================================================================

with_req_sup_test_() ->
    {foreach,
     fun() -> {ok, Pid} = livery_req_sup:start_link(), Pid end,
     fun(Pid) -> stop_sup(Pid) end,
     [
        fun in_flight_zero_when_idle/0,
        fun in_flight_counts_live_workers/0,
        fun await_ok_when_idle/0,
        fun await_times_out_then_succeeds/0
     ]}.

stop_sup(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 1000 -> ok end.

%%====================================================================
%% in_flight/0
%%====================================================================

in_flight_zero_when_idle() ->
    ?assertEqual(0, livery_drain:in_flight()).

in_flight_counts_live_workers() ->
    {Tab, S1} = blocked_worker(),
    {Tab2, S2} = blocked_worker(),
    ?assertEqual(2, livery_drain:in_flight()),
    release(S1), release(S2),
    wait_idle(1000),
    livery_test_adapter:stop(Tab),
    livery_test_adapter:stop(Tab2).

%%====================================================================
%% await/1
%%====================================================================

await_ok_when_idle() ->
    ?assertEqual(ok, livery_drain:await(#{timeout => 100})).

await_times_out_then_succeeds() ->
    {Tab, Sync} = blocked_worker(),
    %% Worker is parked, so a short window times out.
    ?assertEqual({error, timeout},
                 livery_drain:await(#{timeout => 150, poll_interval => 20})),
    %% Release it; await now drains to zero.
    release(Sync),
    ?assertEqual(ok, livery_drain:await(#{timeout => 1000, poll_interval => 20})),
    livery_test_adapter:stop(Tab).

%%====================================================================
%% Helpers: a livery_req_proc worker whose handler blocks until told
%%====================================================================

%% Start one request worker under livery_req_sup whose handler waits
%% for a `{release, Sync}' message. Returns {TestAdapterTab, Sync}.
blocked_worker() ->
    Tab = livery_test_adapter:start(),
    Stream = livery_test_adapter:new_stream(Tab),
    Sync = make_ref(),
    Self = self(),
    Handler = fun(_R) ->
        Self ! {worker_ready, Sync},
        receive {release, Sync} -> ok end,
        livery_resp:text(200, <<"done">>)
    end,
    Req = livery_req:new(#{method => <<"GET">>, path => <<"/">>}),
    {ok, _Pid} = livery_req_sup:start_request(#{
        adapter => livery_test_adapter,
        stream  => Stream,
        req     => Req,
        stack   => [],
        handler => Handler
    }),
    receive {worker_ready, Sync} -> ok after 1000 -> error(worker_never_started) end,
    {Tab, Sync}.

release(Sync) ->
    %% The worker is blocked in its handler; find it and release.
    %% We broadcast to all req_proc children (only the blocked ones
    %% are listening for {release, Sync}).
    [Pid ! {release, Sync}
     || {_, Pid, _, _} <- supervisor:which_children(livery_req_sup),
        is_pid(Pid)],
    ok.

wait_idle(Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_idle_loop(Deadline).

wait_idle_loop(Deadline) ->
    case livery_drain:in_flight() of
        0 -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> error(not_idle);
                false -> timer:sleep(10), wait_idle_loop(Deadline)
            end
    end.
