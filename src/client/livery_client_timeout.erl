-module(livery_client_timeout).
-moduledoc """
Client layer: bound a request to a deadline.

Runs the downstream call in a monitored child process and returns
`{error, timeout}` if it does not finish within `Ms`, killing the child
(which tears down the in-flight connection). Add it with
`livery_client:timeout/1`.

A `{stream, Reader}` response body holds a live connection owned by the
child. Before the child exits, this layer hands that connection to the
caller via the adapter's `adopt/2`, so the caller's later `read/1` does not
race the child's death.
""".

-export([call/3]).

-spec call(livery_client:request(), livery_client:next(), pos_integer()) ->
    {ok, livery_client:response()} | {error, term()}.
call(Req, Next, Ms) ->
    Self = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() ->
        Result =
            try
                Next(Req)
            catch
                Class:Reason:Stack -> {'$crash', Class, Reason, Stack}
            end,
        Self ! {Ref, reparent(Result, Self)}
    end),
    receive
        {Ref, {'$crash', Class, Reason, Stack}} ->
            erlang:demonitor(MRef, [flush]),
            erlang:raise(Class, Reason, Stack);
        {Ref, Result} ->
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, {worker_down, Reason}}
    after Ms ->
        exit(Pid, kill),
        erlang:demonitor(MRef, [flush]),
        {error, timeout}
    end.

%% Hand a streamed response's connection to the caller before this child
%% exits, so it is not torn down with the child. Non-streamed results and
%% adapters without adopt/2 pass through unchanged.
reparent({ok, #{body := {stream, {Adapter, State}}}} = Result, Owner) ->
    _ = adopt(Adapter, State, Owner),
    Result;
reparent(Result, _Owner) ->
    Result.

adopt(Adapter, State, Owner) ->
    case erlang:function_exported(Adapter, adopt, 2) of
        true ->
            try
                Adapter:adopt(State, Owner)
            catch
                _:_ -> ok
            end;
        false ->
            ok
    end.
