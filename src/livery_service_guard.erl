-module(livery_service_guard).
-moduledoc """
Stops a service's listeners when the service dies without stopping them.

The wire libraries run their listeners under their own supervisors, so a
listener does not die with the `livery_service` that started it, and a
service killed or crashed never runs `terminate/2`. Each service starts a
guard that monitors it and holds a stop function per listener. When the
service goes down for any reason, the guard runs them and exits.

Every guard records the addresses it holds in the `livery_service_guards`
table owned by `livery_sup`. A service starting on the same addresses waits
for the guard of a dead service to finish first, so a supervisor restarting
a killed service does not race the old listeners for the port.

Internal to `livery_service`.
""".

-export([start/0, add/3, forget/2, release/1, await_free/1]).
-export([init/1]).

-export_type([key/0]).

-type key() :: {tcp | udp, inet:port_number()} | {quic, atom()}.

-define(TABLE, livery_service_guards).
-define(AWAIT_TIMEOUT, 5000).

-doc """
Start a guard for the calling service. The guard is not linked to anyone,
and it monitors the service before this returns, so nothing the service
sends it can arrive after the service's `'DOWN'`.
""".
-spec start() -> pid().
start() ->
    {ok, Guard} = proc_lib:start(?MODULE, init, [self()]),
    Guard.

-doc """
Hand the guard a started listener: the addresses it holds and how to stop
it. A later `forget/2` with any of the same keys drops it again.
""".
-spec add(pid(), [key()], fun(() -> term())) -> ok.
add(Guard, Keys, Stop) ->
    Guard ! {add, Keys, Stop},
    ok.

-doc "Drop a listener the service already stopped itself.".
-spec forget(pid(), [key()]) -> ok.
forget(Guard, Keys) ->
    Guard ! {forget, Keys},
    ok.

-doc """
Stop every listener the guard still holds, then end the guard. Returns once
they are stopped. This is how the service stops its listeners, on a normal
stop and on a failed start alike.
""".
-spec release(pid()) -> ok.
release(Guard) ->
    MRef = erlang:monitor(process, Guard),
    Guard ! release,
    receive
        {'DOWN', MRef, process, Guard, _} -> ok
    end.

-doc """
Wait for the guards of dead services that still hold any of `Keys` to stop
their listeners, up to five seconds. Addresses held by a live service are
left for the listen call to refuse.
""".
-spec await_free([key()]) -> ok.
await_free(Keys) ->
    case ets:whereis(?TABLE) of
        undefined ->
            ok;
        _ ->
            Guards = lists:usort([
                G
             || K <- Keys,
                {_, G, Service} <- ets:lookup(?TABLE, K),
                not is_process_alive(Service)
            ]),
            Deadline = erlang:monotonic_time(millisecond) + ?AWAIT_TIMEOUT,
            lists:foreach(fun(G) -> await_guard(G, Deadline) end, Guards)
    end.

%%====================================================================
%% Guard process
%%====================================================================

-doc false.
-spec init(pid()) -> ok.
init(Service) ->
    MRef = erlang:monitor(process, Service),
    proc_lib:init_ack(Service, {ok, self()}),
    loop(Service, MRef, []).

loop(Service, MRef, Held) ->
    receive
        {add, Keys, Stop} ->
            record(Keys, Service),
            loop(Service, MRef, [{Keys, Stop} | Held]);
        {forget, Keys} ->
            {Gone, Kept} = lists:partition(fun({Ks, _}) -> overlaps(Ks, Keys) end, Held),
            unrecord(lists:append([Ks || {Ks, _} <- Gone])),
            loop(Service, MRef, Kept);
        release ->
            stop_all(Held);
        {'DOWN', MRef, process, Service, _} ->
            stop_all(Held)
    end.

%% `Held' is newest first, so listeners stop in reverse start order. A stop
%% that fails must not keep the others open.
stop_all(Held) ->
    lists:foreach(
        fun({Keys, Stop}) ->
            try
                Stop()
            catch
                _:_ -> ok
            end,
            unrecord(Keys)
        end,
        Held
    ).

overlaps(A, B) ->
    lists:any(fun(K) -> lists:member(K, B) end, A).

record(Keys, Service) ->
    table_op(fun() -> ets:insert(?TABLE, [{K, self(), Service} || K <- Keys]) end).

unrecord(Keys) ->
    Self = self(),
    table_op(fun() -> [ets:match_delete(?TABLE, {K, Self, '_'}) || K <- Keys] end).

table_op(Fun) ->
    case ets:whereis(?TABLE) of
        undefined ->
            ok;
        _ ->
            _ = Fun(),
            ok
    end.

%% A guard that is already gone has nothing left to stop. Rows it left
%% behind (it was killed) are removed so they are not waited on again.
await_guard(Guard, Deadline) ->
    MRef = erlang:monitor(process, Guard),
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'DOWN', MRef, process, Guard, _} ->
            _ = ets:match_delete(?TABLE, {'_', Guard, '_'}),
            ok
    after Timeout ->
        erlang:demonitor(MRef, [flush]),
        ok
    end.
