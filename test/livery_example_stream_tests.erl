%% @doc Drives the streaming example's producer through the in-memory
%% adapter, so the concept doc's receive-loop pattern stays correct.
-module(livery_example_stream_tests).
-include_lib("eunit/include/eunit.hrl").

%% A small count and a tiny interval keep the test fast: the producer
%% runs synchronously inside livery_test_adapter:run/3.
emits_n_sse_frames_test() ->
    Handler = fun(_Req) ->
        livery_resp:sse(200, fun(Emit) -> livery_example_stream:tick(Emit, 3, 5) end)
    end,
    Cap = livery_test_adapter:run([], Handler, #{method => <<"GET">>}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    Body = livery_test_adapter:body(Cap),
    ?assertEqual(3, count_substr(Body, <<"event: tick">>)).

%% Zero ticks: the loop returns immediately, no frames.
emits_nothing_when_count_zero_test() ->
    Handler = fun(_Req) ->
        livery_resp:sse(200, fun(Emit) -> livery_example_stream:tick(Emit, 0, 5) end)
    end,
    Cap = livery_test_adapter:run([], Handler, #{method => <<"GET">>}),
    ?assertEqual(<<>>, livery_test_adapter:body(Cap)).

count_substr(Haystack, Needle) ->
    case binary:matches(Haystack, Needle) of
        nomatch -> 0;
        Matches -> length(Matches)
    end.
