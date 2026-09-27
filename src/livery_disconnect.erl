-module(livery_disconnect).
-moduledoc """
Internal helper for delivering a client-disconnect signal.

Called by the per-stream translator in each adapter when the client
resets the stream or closes the connection. It signals the request
worker two ways: a `{livery_disconnect, Ref, Reason}` message (for a
handler waiting in a `receive` loop) and a spawned run of each
registered cancel callback (for a handler blocked in a NIF that would
not see a mailbox message until it returns).

Callbacks are always run in a fresh process via `spawn/1`, so a slow
or crashing callback cannot block the translator or delay the worker's
`'DOWN'` cleanup.

A reset livery issues itself is not a disconnect, but some transports
echo it back to the translator as a stream reset. Before resetting, the
worker calls `local_reset/0`, which tells the translator to treat the
disconnect as already handled.
""".

-export([fire/4, fire_once/5, register/3, set_notifier/2, local_reset/0]).

-define(NOTIFIER_KEY, livery_notifier).

-doc """
Signal `WorkerPid` that the client for `Ref` disconnected with
`Reason`, and spawn each registered cancel callback.
""".
-spec fire(pid(), reference(), term(), [fun(() -> term())]) -> ok.
fire(WorkerPid, Ref, Reason, Callbacks) ->
    WorkerPid ! {livery_disconnect, Ref, Reason},
    lists:foreach(fun run/1, Callbacks),
    ok.

-doc """
Fire on the first disconnect only. Returns the new `fired` flag
(always `true`). A no-op when already fired, so a stream reset
followed by a connection close fires once.
""".
-spec fire_once(boolean(), pid(), reference(), term(), [fun(() -> term())]) -> true.
fire_once(true, _WorkerPid, _Ref, _Reason, _Callbacks) ->
    true;
fire_once(false, WorkerPid, Ref, Reason, Callbacks) ->
    ok = fire(WorkerPid, Ref, Reason, Callbacks),
    true.

-doc """
Register a cancel callback. If the disconnect already fired, run it
immediately (spawned) and leave the list unchanged; otherwise prepend
it for the eventual fire.
""".
-spec register(boolean(), fun(() -> term()), [fun(() -> term())]) ->
    [fun(() -> term())].
register(true, Fun, Callbacks) ->
    ok = run(Fun),
    Callbacks;
register(false, Fun, Callbacks) ->
    [Fun | Callbacks].

-spec run(fun(() -> term())) -> ok.
run(Fun) ->
    _ = spawn(Fun),
    ok.

-doc """
Remember, in the calling request worker, which translator to tell
about a local reset. Without a notifier there is nothing to tell.
""".
-spec set_notifier(pid() | undefined, reference() | undefined) -> ok.
set_notifier(Pid, Ref) when is_pid(Pid), is_reference(Ref) ->
    _ = put(?NOTIFIER_KEY, {Pid, Ref}),
    ok;
set_notifier(_Pid, _Ref) ->
    ok.

-doc """
Tell the translator that livery is about to reset the stream, so the
reset it may see next does not fire the cancel callbacks. A no-op
outside a request worker. Call it before the reset: the marker then
reaches the translator ahead of the echo.
""".
-spec local_reset() -> ok.
local_reset() ->
    case get(?NOTIFIER_KEY) of
        {Pid, Ref} ->
            Pid ! {livery_local_reset, Ref},
            ok;
        undefined ->
            ok
    end.
