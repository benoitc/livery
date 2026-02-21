%% @doc Graceful shutdown support for Livery HTTP server.
%%
%% Provides graceful shutdown functionality that:
%% - Stops accepting new connections
%% - Allows in-flight requests to complete
%% - Sends appropriate protocol-level shutdown signals (GOAWAY for H2/H3)
%% - Enforces a shutdown timeout
%%
%% == Usage ==
%%
%% ```
%% %% Graceful shutdown with 30 second timeout
%% ok = livery_shutdown:graceful(my_listener, 30000).
%%
%% %% Immediate shutdown
%% ok = livery_shutdown:immediate(my_listener).
%%
%% %% Shutdown all listeners
%% ok = livery_shutdown:shutdown_all(30000).
%% '''
-module(livery_shutdown).

-export([
    graceful/2,
    immediate/1,
    shutdown_all/1,
    drain_connections/2
]).

%% Default shutdown timeout
-define(DEFAULT_TIMEOUT, 30000).

%%====================================================================
%% API
%%====================================================================

%% @doc Gracefully shutdown a listener.
%% Stops accepting new connections and waits for existing connections
%% to complete or timeout.
-spec graceful(atom(), timeout()) -> ok | {error, term()}.
graceful(ListenerName, Timeout) ->
    case get_listener_pid(ListenerName) of
        {ok, AcceptorSupPid} ->
            %% Stop acceptors (no new connections)
            stop_acceptors(AcceptorSupPid),

            %% Get all connection processes
            Connections = get_connections(AcceptorSupPid),

            %% Signal connections to drain
            signal_drain(Connections),

            %% Wait for connections to close
            wait_connections(Connections, Timeout),

            %% Stop the listener supervisor
            livery_sup:stop_listener(ListenerName);
        {error, _} = Error ->
            Error
    end.

%% @doc Immediately shutdown a listener.
%% Terminates all connections without waiting.
-spec immediate(atom()) -> ok | {error, term()}.
immediate(ListenerName) ->
    livery:stop_listener(ListenerName).

%% @doc Shutdown all listeners gracefully.
-spec shutdown_all(timeout()) -> ok.
shutdown_all(Timeout) ->
    Listeners = livery:which_listeners(),
    %% Shutdown all listeners in parallel
    Refs = lists:map(fun(Listener) ->
        Ref = make_ref(),
        Self = self(),
        spawn_link(fun() ->
            Result = graceful(Listener, Timeout),
            Self ! {shutdown_done, Ref, Listener, Result}
        end),
        {Ref, Listener}
    end, Listeners),

    %% Wait for all to complete
    lists:foreach(fun({Ref, Listener}) ->
        receive
            {shutdown_done, Ref, Listener, _Result} -> ok
        after Timeout + 1000 ->
            %% Force stop if graceful didn't complete
            catch immediate(Listener)
        end
    end, Refs),
    ok.

%% @doc Drain connections from a connection pool.
%% Used internally for graceful shutdown.
-spec drain_connections([pid()], timeout()) -> ok.
drain_connections(Connections, Timeout) ->
    signal_drain(Connections),
    wait_connections(Connections, Timeout).

%%====================================================================
%% Internal Functions
%%====================================================================

get_listener_pid(ListenerName) ->
    %% Find the acceptor supervisor for this listener
    case supervisor:which_children(livery_sup) of
        Children when is_list(Children) ->
            case lists:keyfind(ListenerName, 1, Children) of
                {ListenerName, Pid, supervisor, _} when is_pid(Pid) ->
                    {ok, Pid};
                _ ->
                    {error, not_found}
            end;
        _ ->
            {error, not_found}
    end.

stop_acceptors(AcceptorSupPid) ->
    %% Get acceptor children and stop them
    case supervisor:which_children(AcceptorSupPid) of
        Children when is_list(Children) ->
            lists:foreach(fun({Id, Pid, worker, _}) when is_pid(Pid) ->
                %% Terminate acceptor - it will stop accepting
                supervisor:terminate_child(AcceptorSupPid, Id);
               (_) -> ok
            end, Children);
        _ ->
            ok
    end.

get_connections(AcceptorSupPid) ->
    %% In our architecture, connections are linked to acceptors
    %% We need to find all connection processes
    %% For now, we use process dictionary or registered names
    %% This is a simplified version - in production you'd track connections
    case erlang:process_info(AcceptorSupPid, links) of
        {links, Links} ->
            %% Filter to only connection processes
            [Pid || Pid <- Links, is_connection_process(Pid)];
        _ ->
            []
    end.

is_connection_process(Pid) ->
    case erlang:process_info(Pid, initial_call) of
        {initial_call, {livery_connection, init, _}} -> true;
        {initial_call, {proc_lib, init_p, _}} ->
            %% Check dictionary for gen_statem
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

signal_drain(Connections) ->
    %% Send drain signal to all connections
    lists:foreach(fun(Pid) ->
        %% Use gen_statem cast to signal draining
        catch gen_statem:cast(Pid, drain)
    end, Connections).

wait_connections([], _Timeout) ->
    ok;
wait_connections(Connections, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_connections_loop(Connections, Deadline).

wait_connections_loop([], _Deadline) ->
    ok;
wait_connections_loop(Connections, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            %% Timeout - force close remaining connections
            lists:foreach(fun(Pid) ->
                catch exit(Pid, shutdown)
            end, Connections),
            ok;
        false ->
            %% Check which connections are still alive
            Remaining = [Pid || Pid <- Connections, is_process_alive(Pid)],
            case Remaining of
                [] ->
                    ok;
                _ ->
                    %% Wait a bit and check again
                    timer:sleep(100),
                    wait_connections_loop(Remaining, Deadline)
            end
    end.
