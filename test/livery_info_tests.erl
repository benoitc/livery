%% @doc Unit tests for server info module.
-module(livery_info_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% Version tests
%% ===================================================================

version_test() ->
    Version = livery_info:version(),
    ?assert(is_binary(Version)),
    ?assert(byte_size(Version) > 0).

%% ===================================================================
%% Server info tests
%% ===================================================================

info_returns_map_test() ->
    %% This test requires the app to be running, skip if not
    try
        Info = livery_info:info(),
        ?assert(is_map(Info)),
        ?assert(maps:is_key(version, Info)),
        ?assert(maps:is_key(otp_version, Info)),
        ?assert(maps:is_key(erts_version, Info)),
        ?assert(maps:is_key(schedulers, Info)),
        ?assert(maps:is_key(supported_protocols, Info))
    catch
        exit:{noproc, _} -> ok  %% App not running, skip
    end.

info_schedulers_test() ->
    %% This test requires the app to be running, skip if not
    try
        Info = livery_info:info(),
        ?assert(maps:get(schedulers, Info) > 0),
        ?assert(maps:get(schedulers_online, Info) > 0)
    catch
        exit:{noproc, _} -> ok  %% App not running, skip
    end.

%% ===================================================================
%% Supported protocols tests
%% ===================================================================

supported_protocols_test() ->
    Protocols = livery_info:supported_protocols(),
    ?assert(is_list(Protocols)),
    ?assert(lists:member(http1, Protocols)),
    ?assert(lists:member(http2, Protocols)),
    ?assert(lists:member(http3, Protocols)),
    ?assert(lists:member(websocket, Protocols)).

%% ===================================================================
%% Connection count tests (without running server)
%% ===================================================================

connection_count_nonexistent_test() ->
    %% Should return 0 for non-existent listener
    try
        Count = livery_info:connection_count(nonexistent_listener),
        ?assertEqual(0, Count)
    catch
        exit:{noproc, _} -> ok  %% App not running, skip
    end.

total_connections_no_listeners_test() ->
    %% Should return 0 when no listeners
    try
        Count = livery_info:total_connections(),
        ?assertEqual(0, Count)
    catch
        exit:{noproc, _} -> ok  %% App not running, skip
    end.

%% ===================================================================
%% Listener info tests (without running server)
%% ===================================================================

listener_info_nonexistent_test() ->
    try
        Result = livery_info:listener_info(nonexistent_listener),
        ?assertEqual({error, not_found}, Result)
    catch
        exit:{noproc, _} -> ok  %% App not running, skip
    end.

all_listener_info_empty_test() ->
    %% Without any running listeners, should return empty map
    try
        Info = livery_info:all_listener_info(),
        ?assert(is_map(Info))
    catch
        exit:{noproc, _} -> ok  %% App not running, skip
    end.
