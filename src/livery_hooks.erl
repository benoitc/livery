%% @doc Hook system for Livery HTTP server.
%%
%% Provides a simple callback-based event system for observability.
%% Hooks are registered per event name and called synchronously.
%%
%% == Events ==
%%
%% === Connection Events ===
%% - `connection_start' - Connection accepted
%%   Data: `#{listener => atom(), peer => {ip(), port()}, transport => tcp | ssl}'
%%
%% - `connection_stop' - Connection closed
%%   Data: `#{listener => atom(), peer => {ip(), port()}, reason => term(), duration => integer()}'
%%
%% === Request Events ===
%% - `request_start' - Request received
%%   Data: `#{method => binary(), path => binary(), protocol => h1 | h2 | h3}'
%%
%% - `request_stop' - Request completed
%%   Data: `#{method => binary(), path => binary(), status => integer(),
%%            duration => integer(), resp_body_size => integer()}'
%%
%% - `request_exception' - Request failed with exception
%%   Data: `#{method => binary(), path => binary(), kind => error | exit | throw,
%%            reason => term(), stacktrace => list(), duration => integer()}'
%%
%% === WebSocket Events ===
%% - `websocket_upgrade' - WebSocket upgrade
%%   Data: `#{path => binary()}'
%%
%% - `websocket_frame' - WebSocket frame sent/received
%%   Data: `#{direction => in | out, opcode => atom(), size => integer()}'
%%
%% == Usage ==
%%
%% ```
%% %% Add a hook
%% livery_hooks:add(request_stop, fun(Data) ->
%%     #{method := Method, path := Path, status := Status, duration := Duration} = Data,
%%     io:format("~s ~s -> ~p (~p us)~n", [Method, Path, Status, Duration])
%% end).
%%
%% %% Remove a hook
%% livery_hooks:delete(request_stop, HookRef).
%%
%% %% List hooks
%% livery_hooks:list(request_stop).
%% '''
-module(livery_hooks).

-export([
    %% Hook management
    add/2,
    add/3,
    delete/2,
    list/1,
    %% Hook execution
    run/2,
    %% Convenience functions for common events
    connection_start/1,
    connection_stop/1,
    request_start/1,
    request_stop/1,
    request_exception/1,
    websocket_upgrade/1,
    websocket_frame/1
]).

-define(TABLE, livery_hooks).

%%====================================================================
%% Hook Management
%%====================================================================

%% @doc Add a hook for an event.
%% Returns a reference that can be used to delete the hook.
-spec add(atom(), fun((map()) -> any())) -> reference().
add(Event, Fun) when is_atom(Event), is_function(Fun, 1) ->
    add(Event, Fun, undefined).

%% @doc Add a hook for an event with a tag for identification.
-spec add(atom(), fun((map()) -> any()), term()) -> reference().
add(Event, Fun, Tag) when is_atom(Event), is_function(Fun, 1) ->
    Ref = make_ref(),
    ets:insert(?TABLE, {{Event, Ref}, Fun, Tag}),
    Ref.

%% @doc Delete a hook by its reference.
-spec delete(atom(), reference()) -> ok.
delete(Event, Ref) when is_atom(Event), is_reference(Ref) ->
    ets:delete(?TABLE, {Event, Ref}),
    ok.

%% @doc List all hooks for an event.
-spec list(atom()) -> [{reference(), term()}].
list(Event) when is_atom(Event) ->
    [{Ref, Tag} || {{E, Ref}, _Fun, Tag} <- ets:tab2list(?TABLE), E =:= Event].

%%====================================================================
%% Hook Execution
%%====================================================================

%% @doc Run all hooks for an event with the given data.
%% Hooks are called synchronously. Exceptions in hooks are caught and logged.
-spec run(atom(), map()) -> ok.
run(Event, Data) when is_atom(Event), is_map(Data) ->
    Hooks = ets:match_object(?TABLE, {{Event, '_'}, '_', '_'}),
    lists:foreach(fun({{_, _Ref}, Fun, _Tag}) ->
        try
            Fun(Data)
        catch
            Kind:Reason:Stack ->
                error_logger:warning_msg(
                    "[livery_hooks] Hook for ~p failed: ~p:~p~n~p~n",
                    [Event, Kind, Reason, Stack])
        end
    end, Hooks),
    ok.

%%====================================================================
%% Convenience Functions
%%====================================================================

%% @doc Run connection_start hooks.
-spec connection_start(map()) -> ok.
connection_start(Data) ->
    run(connection_start, Data#{system_time => erlang:system_time()}).

%% @doc Run connection_stop hooks.
-spec connection_stop(map()) -> ok.
connection_stop(Data) ->
    run(connection_stop, Data).

%% @doc Run request_start hooks.
-spec request_start(map()) -> ok.
request_start(Data) ->
    run(request_start, Data#{system_time => erlang:system_time()}).

%% @doc Run request_stop hooks.
-spec request_stop(map()) -> ok.
request_stop(Data) ->
    run(request_stop, Data).

%% @doc Run request_exception hooks.
-spec request_exception(map()) -> ok.
request_exception(Data) ->
    run(request_exception, Data).

%% @doc Run websocket_upgrade hooks.
-spec websocket_upgrade(map()) -> ok.
websocket_upgrade(Data) ->
    run(websocket_upgrade, Data#{system_time => erlang:system_time()}).

%% @doc Run websocket_frame hooks.
-spec websocket_frame(map()) -> ok.
websocket_frame(Data) ->
    run(websocket_frame, Data).
