-module(livery_send_retry_tests).

-include_lib("eunit/include/eunit.hrl").

deadline(Ms) ->
    erlang:monotonic_time(millisecond) + Ms.

%% Returns send_queue_full N times, then ok.
flaky(N) ->
    Counter = counters:new(1, []),
    Send = fun() ->
        case counters:get(Counter, 1) < N of
            true ->
                counters:add(Counter, 1, 1),
                {error, send_queue_full};
            false ->
                ok
        end
    end,
    {Send, Counter}.

succeeds_after_backpressure_test() ->
    {Send, Counter} = flaky(5),
    ?assertEqual(ok, livery_send_retry:run(Send, deadline(5000))),
    ?assertEqual(5, counters:get(Counter, 1)).

times_out_test() ->
    Send = fun() -> {error, send_queue_full} end,
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, send_timeout}, livery_send_retry:run(Send, deadline(100))),
    ?assert(erlang:monotonic_time(millisecond) - T0 >= 100).

other_error_not_retried_test() ->
    Counter = counters:new(1, []),
    Send = fun() ->
        counters:add(Counter, 1, 1),
        {error, closed}
    end,
    ?assertEqual({error, closed}, livery_send_retry:run(Send, deadline(5000))),
    ?assertEqual(1, counters:get(Counter, 1)).
