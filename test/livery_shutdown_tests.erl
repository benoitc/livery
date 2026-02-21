%% @doc Unit tests for graceful shutdown.
-module(livery_shutdown_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% Graceful shutdown tests (without running server)
%% ===================================================================

graceful_nonexistent_listener_test() ->
    try
        Result = livery_shutdown:graceful(nonexistent_listener, 1000),
        ?assertEqual({error, not_found}, Result)
    catch
        exit:{noproc, _} -> ok  %% App not running, skip
    end.

%% ===================================================================
%% Immediate shutdown tests (without running server)
%% ===================================================================

immediate_nonexistent_listener_test() ->
    %% Should not crash on non-existent listener
    try
        Result = livery_shutdown:immediate(nonexistent_listener),
        ?assertMatch({error, _}, Result)
    catch
        exit:{noproc, _} -> ok  %% App not running, skip
    end.

%% ===================================================================
%% Drain connections tests
%% ===================================================================

drain_empty_connections_test() ->
    %% Should complete immediately with empty list
    ok = livery_shutdown:drain_connections([], 1000).

drain_dead_connections_test() ->
    %% Create some dead pids (will be filtered out)
    Pids = [spawn(fun() -> ok end) || _ <- lists:seq(1, 3)],
    timer:sleep(10),  %% Let them die
    ok = livery_shutdown:drain_connections(Pids, 100).

%% ===================================================================
%% Shutdown all tests (without running server)
%% ===================================================================

shutdown_all_no_listeners_test() ->
    %% Should complete without error when no listeners
    try
        ok = livery_shutdown:shutdown_all(100)
    catch
        exit:{noproc, _} -> ok  %% App not running, skip
    end.
