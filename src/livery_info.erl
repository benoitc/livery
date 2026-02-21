%% @doc Server information and statistics for Livery HTTP server.
%%
%% Provides runtime information about the server including:
%% - Active connections count
%% - Listener status
%% - Protocol statistics
%%
%% == Usage ==
%%
%% ```
%% %% Get server info
%% #{version := Version, listeners := Listeners} = livery_info:info().
%%
%% %% Get listener-specific info
%% #{port := Port, connections := N} = livery_info:listener_info(my_http).
%%
%% %% Get connection count
%% Count = livery_info:connection_count(my_http).
%% '''
-module(livery_info).

-export([
    %% Server info
    info/0,
    version/0,
    %% Listener info
    listener_info/1,
    all_listener_info/0,
    %% Connection stats
    connection_count/1,
    total_connections/0,
    %% Protocol info
    supported_protocols/0
]).

%% Server version
-define(VERSION, <<"1.0.0">>).

%%====================================================================
%% Server Info
%%====================================================================

%% @doc Get overall server information.
-spec info() -> map().
info() ->
    #{
        version => version(),
        otp_version => list_to_binary(erlang:system_info(otp_release)),
        erts_version => list_to_binary(erlang:system_info(version)),
        schedulers => erlang:system_info(schedulers),
        schedulers_online => erlang:system_info(schedulers_online),
        listeners => livery:which_listeners(),
        total_connections => total_connections(),
        supported_protocols => supported_protocols(),
        uptime => uptime()
    }.

%% @doc Get server version.
-spec version() -> binary().
version() ->
    case application:get_key(livery, vsn) of
        {ok, Vsn} -> list_to_binary(Vsn);
        undefined -> ?VERSION
    end.

%% @doc Get server uptime in milliseconds.
-spec uptime() -> non_neg_integer().
uptime() ->
    case application:get_env(livery, start_time) of
        {ok, StartTime} ->
            erlang:system_time(millisecond) - StartTime;
        undefined ->
            0
    end.

%%====================================================================
%% Listener Info
%%====================================================================

%% @doc Get information about a specific listener.
-spec listener_info(atom()) -> map() | {error, not_found}.
listener_info(ListenerName) ->
    case get_listener_state(ListenerName) of
        {ok, State} ->
            State;
        {error, _} = Error ->
            Error
    end.

%% @doc Get information about all listeners.
-spec all_listener_info() -> #{atom() => map()}.
all_listener_info() ->
    Listeners = livery:which_listeners(),
    maps:from_list([{L, listener_info(L)} || L <- Listeners]).

%% @private Get listener state from supervisor
get_listener_state(ListenerName) ->
    case supervisor:which_children(livery_sup) of
        Children when is_list(Children) ->
            case lists:keyfind(ListenerName, 1, Children) of
                {ListenerName, Pid, supervisor, _} when is_pid(Pid) ->
                    build_listener_info(ListenerName, Pid);
                _ ->
                    {error, not_found}
            end;
        _ ->
            {error, not_found}
    end.

build_listener_info(Name, AcceptorSupPid) ->
    %% Count acceptors and connections
    AcceptorCount = count_acceptors(AcceptorSupPid),
    ConnCount = count_connections(AcceptorSupPid),

    {ok, #{
        name => Name,
        acceptors => AcceptorCount,
        connections => ConnCount,
        status => running
    }}.

count_acceptors(AcceptorSupPid) ->
    case supervisor:which_children(AcceptorSupPid) of
        Children when is_list(Children) ->
            length([C || {_, Pid, worker, _} = C <- Children, is_pid(Pid)]);
        _ ->
            0
    end.

count_connections(AcceptorSupPid) ->
    %% Count linked connection processes
    case erlang:process_info(AcceptorSupPid, links) of
        {links, Links} ->
            length([Pid || Pid <- Links, is_connection_process(Pid)]);
        _ ->
            0
    end.

is_connection_process(Pid) ->
    case erlang:process_info(Pid, initial_call) of
        {initial_call, {livery_connection, init, _}} -> true;
        {initial_call, {proc_lib, init_p, _}} ->
            case erlang:process_info(Pid, dictionary) of
                {dictionary, Dict} ->
                    case proplists:get_value('$initial_call', Dict) of
                        {livery_connection, init, _} -> true;
                        _ -> false
                    end;
                _ -> false
            end;
        _ -> false
    end.

%%====================================================================
%% Connection Stats
%%====================================================================

%% @doc Get connection count for a listener.
-spec connection_count(atom()) -> non_neg_integer().
connection_count(ListenerName) ->
    case listener_info(ListenerName) of
        #{connections := Count} -> Count;
        _ -> 0
    end.

%% @doc Get total connection count across all listeners.
-spec total_connections() -> non_neg_integer().
total_connections() ->
    Listeners = livery:which_listeners(),
    lists:sum([connection_count(L) || L <- Listeners]).

%%====================================================================
%% Protocol Info
%%====================================================================

%% @doc Get list of supported protocols.
-spec supported_protocols() -> [atom()].
supported_protocols() ->
    [http1, http2, http3, websocket].
