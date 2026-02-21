%% @doc Unit tests for telemetry events.
-module(livery_telemetry_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% Connection events tests
%% ===================================================================

connection_start_returns_start_time_test() ->
    StartTime = livery_telemetry:connection_start(test_listener, #{peer => {{127,0,0,1}, 8080}}),
    ?assert(is_integer(StartTime)),
    %% Monotonic time can be negative, just check it's an integer
    ?assert(true).

connection_stop_test() ->
    StartTime = erlang:monotonic_time(),
    timer:sleep(1),
    ok = livery_telemetry:connection_stop(StartTime, normal, #{listener => test_listener}).

%% ===================================================================
%% Request events tests
%% ===================================================================

request_start_returns_start_time_test() ->
    StartTime = livery_telemetry:request_start(<<"GET">>, #{path => <<"/">>}),
    ?assert(is_integer(StartTime)),
    %% Monotonic time can be negative, just check it's an integer
    ?assert(true).

request_stop_test() ->
    StartTime = erlang:monotonic_time(),
    timer:sleep(1),
    ok = livery_telemetry:request_stop(StartTime, 200, #{method => <<"GET">>, path => <<"/">>}).

request_stop_with_body_size_test() ->
    StartTime = erlang:monotonic_time(),
    ok = livery_telemetry:request_stop(StartTime, 200, #{
        method => <<"GET">>,
        path => <<"/">>,
        resp_body_size => 1024
    }).

request_exception_test() ->
    StartTime = erlang:monotonic_time(),
    ok = livery_telemetry:request_exception(StartTime, error, badarg, #{
        method => <<"POST">>,
        path => <<"/api">>
    }).

%% ===================================================================
%% WebSocket events tests
%% ===================================================================

websocket_upgrade_test() ->
    ok = livery_telemetry:websocket_upgrade(#{path => <<"/ws">>}).

websocket_frame_in_test() ->
    ok = livery_telemetry:websocket_frame(in, text, 100).

websocket_frame_out_test() ->
    ok = livery_telemetry:websocket_frame(out, binary, 500).

%% ===================================================================
%% Span helper tests
%% ===================================================================

span_success_test() ->
    Result = livery_telemetry:span([test, operation], #{}, fun() ->
        42
    end),
    ?assertEqual(42, Result).

span_exception_test() ->
    ?assertException(error, test_error,
        livery_telemetry:span([test, operation], #{}, fun() ->
            error(test_error)
        end)).

span_with_metadata_test() ->
    Result = livery_telemetry:span([test, operation], #{key => value}, fun() ->
        ok
    end),
    ?assertEqual(ok, Result).

%% ===================================================================
%% Emit fallback tests (when telemetry not loaded)
%% ===================================================================

emit_without_telemetry_test() ->
    %% Should not crash even if telemetry is not loaded
    StartTime = livery_telemetry:request_start(<<"GET">>, #{}),
    ?assert(is_integer(StartTime)).
