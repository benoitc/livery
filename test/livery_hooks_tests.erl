-module(livery_hooks_tests).

-include_lib("eunit/include/eunit.hrl").

%% Setup/teardown for tests that need the ETS table
setup() ->
    case ets:whereis(livery_hooks) of
        undefined ->
            ets:new(livery_hooks, [named_table, public, bag, {read_concurrency, true}]);
        _ ->
            ets:delete_all_objects(livery_hooks)
    end,
    ok.

add_hook_test() ->
    setup(),
    Ref = livery_hooks:add(test_event, fun(_) -> ok end),
    ?assert(is_reference(Ref)),
    [{Ref, undefined}] = livery_hooks:list(test_event).

add_hook_with_tag_test() ->
    setup(),
    Ref = livery_hooks:add(test_event, fun(_) -> ok end, my_tag),
    ?assert(is_reference(Ref)),
    [{Ref, my_tag}] = livery_hooks:list(test_event).

delete_hook_test() ->
    setup(),
    Ref = livery_hooks:add(test_event, fun(_) -> ok end),
    ok = livery_hooks:delete(test_event, Ref),
    [] = livery_hooks:list(test_event).

run_hook_test() ->
    setup(),
    Self = self(),
    livery_hooks:add(test_event, fun(Data) -> Self ! {hook_called, Data} end),
    ok = livery_hooks:run(test_event, #{key => value}),
    receive
        {hook_called, #{key := value}} -> ok
    after 100 ->
        ?assert(false)
    end.

run_multiple_hooks_test() ->
    setup(),
    Self = self(),
    livery_hooks:add(test_event, fun(_) -> Self ! hook1 end),
    livery_hooks:add(test_event, fun(_) -> Self ! hook2 end),
    ok = livery_hooks:run(test_event, #{}),
    receive hook1 -> ok after 100 -> ?assert(false) end,
    receive hook2 -> ok after 100 -> ?assert(false) end.

hook_exception_handled_test() ->
    setup(),
    Self = self(),
    %% Add a failing hook
    livery_hooks:add(test_event, fun(_) -> error(intentional_error) end),
    %% Add a hook after the failing one
    livery_hooks:add(test_event, fun(_) -> Self ! hook_after_error end),
    %% Run should not crash
    ok = livery_hooks:run(test_event, #{}),
    %% The second hook should still be called
    receive hook_after_error -> ok after 100 -> ?assert(false) end.

connection_start_test() ->
    setup(),
    Self = self(),
    livery_hooks:add(connection_start, fun(Data) -> Self ! {conn_start, Data} end),
    ok = livery_hooks:connection_start(#{listener => test, peer => {{127,0,0,1}, 8080}}),
    receive
        {conn_start, #{listener := test, peer := {{127,0,0,1}, 8080}, system_time := _}} -> ok
    after 100 ->
        ?assert(false)
    end.

request_stop_test() ->
    setup(),
    Self = self(),
    livery_hooks:add(request_stop, fun(Data) -> Self ! {req_stop, Data} end),
    ok = livery_hooks:request_stop(#{method => <<"GET">>, path => <<"/">>, status => 200}),
    receive
        {req_stop, #{method := <<"GET">>, status := 200}} -> ok
    after 100 ->
        ?assert(false)
    end.

list_empty_test() ->
    setup(),
    [] = livery_hooks:list(nonexistent_event).
