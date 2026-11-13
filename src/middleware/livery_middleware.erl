-module(livery_middleware).
-moduledoc """
Tower-style middleware pipeline.

A stack is an ordered list of middleware entries, each of which is
either:

- a `{Module, State}` tuple where `Module` implements the
  `livery_middleware` behaviour (`call/3`); or
- a fun `fun((Req, Next) -> Resp)`.

The pipeline terminates in a handler, which is either
`{Module, Function}` or a fun `fun((Req) -> Resp)`. `run/3` walks
the stack, threading a `Next` continuation that invokes the rest
of the stack plus the handler. Middleware can short-circuit
(never call `Next`), transform the request before calling `Next`,
transform the response after, or both.

## Callback

- `call(Req, Next, State) -> Resp`: invoke the middleware with
  the request, the next continuation, and the per-instance state.
""".

-include("livery.hrl").

-export([
    run/3,
    before/1,
    after_response/1,
    wrap/1,
    after_emit/1,
    with_emit_hooks/1,
    capture_context/1,
    adopt_context/1
]).

-define(EMIT_HOOKS, '$livery_after_emit').

-export_type([stack/0, entry/0, next/0, handler/0, context/0]).

-type req() :: #livery_req{}.
-type resp() :: #livery_resp{}.
-type next() :: fun((req()) -> resp()).

-type entry() ::
    {module(), term()}
    | fun((req(), next()) -> resp()).
-type stack() :: [entry()].

-type handler() ::
    {module(), atom()}
    | fun((req()) -> resp()).

-opaque context() :: [{term(), term()}].

-callback call(req(), next(), term()) -> resp().

-doc "Execute the middleware stack followed by the handler.".
-spec run(stack(), handler(), req()) -> resp().
run([], Handler, Req) ->
    call_handler(Handler, Req);
run([Entry | Rest], Handler, Req) ->
    Next = fun(R) -> run(Rest, Handler, R) end,
    call_entry(Entry, Req, Next).

%%====================================================================
%% Sugar
%%====================================================================

-doc """
Lift a request transformer into a middleware entry.

The returned entry calls `Fun(Req)` to derive a new request, then
invokes the rest of the pipeline.
""".
-spec before(fun((req()) -> req())) -> entry().
before(Fun) when is_function(Fun, 1) ->
    fun(Req, Next) -> Next(Fun(Req)) end.

-doc "Lift a response transformer into a middleware entry.".
-spec after_response(fun((resp()) -> resp())) -> entry().
after_response(Fun) when is_function(Fun, 1) ->
    fun(Req, Next) -> Fun(Next(Req)) end.

-doc """
Wrap the downstream call in a try/catch.

`Fun` is called as `Fun(Class, Reason, Stacktrace)` and must
return a `#livery_resp{}`. Intended for top-of-stack error
recovery. `Class` is `throw | error | exit`.
""".
-spec wrap(fun((throw | error | exit, term(), list()) -> resp())) -> entry().
wrap(Fun) when is_function(Fun, 3) ->
    fun(Req, Next) ->
        try
            Next(Req)
        catch
            Class:Reason:Stack -> Fun(Class, Reason, Stack)
        end
    end.

%%====================================================================
%% Dispatch helpers
%%====================================================================

-spec call_entry(entry(), req(), next()) -> resp().
call_entry({Mod, State}, Req, Next) when is_atom(Mod) ->
    Mod:call(Req, Next, State);
call_entry(Fun, Req, Next) when is_function(Fun, 2) ->
    Fun(Req, Next).

-spec call_handler(handler(), req()) -> resp().
call_handler({Mod, Fun}, Req) when is_atom(Mod), is_atom(Fun) ->
    Mod:Fun(Req);
call_handler(Fun, Req) when is_function(Fun, 1) ->
    Fun(Req).

-doc """
Run `Fun` once the response to the current request has been sent, or
the attempt has ended (peer gone, handler crash). Middleware that holds
a resource for the whole request, response streaming included, releases
it here. Returns `unsupported` when the stack is not running inside a
Livery request worker (for example `livery:dispatch/3` called
directly); nothing is registered then, and the caller should release on
its own.
""".
-spec after_emit(fun(() -> term())) -> ok | unsupported.
after_emit(Fun) when is_function(Fun, 0) ->
    case get(?EMIT_HOOKS) of
        undefined ->
            unsupported;
        {forward, Pid, Tag} ->
            %% Running for a worker in another process: hand the hook
            %% over now, so it still runs if this process is killed.
            Pid ! {Tag, {after_emit, Fun}},
            ok;
        Hooks ->
            put(?EMIT_HOOKS, [Fun | Hooks]),
            ok
    end.

-doc false.
%% Used by the request worker and the test adapter around dispatch and
%% emit: hooks registered with `after_emit/1' run when `Fun' returns or
%% raises, latest first.
-spec with_emit_hooks(fun(() -> R)) -> R.
with_emit_hooks(Fun) ->
    Outer = put(?EMIT_HOOKS, []),
    try
        Fun()
    after
        Hooks = get(?EMIT_HOOKS),
        restore(Outer),
        [
            try
                H()
            catch
                _:_ -> ok
            end
         || H <- Hooks
        ]
    end.

restore(undefined) -> erase(?EMIT_HOOKS);
restore(Outer) -> put(?EMIT_HOOKS, Outer).

-doc false.
%% For a middleware that runs `Next' in another process (see
%% livery_timeout): what the pipeline keeps in this worker's process
%% dictionary, to be adopted by that process. Emit hooks registered
%% there are sent back as `{Tag, {after_emit, Fun}}' messages, which the
%% worker registers with `after_emit/1'. Process identity and the random
%% seed stay behind.
-spec capture_context(reference()) -> context().
capture_context(Tag) ->
    Hooks =
        case get(?EMIT_HOOKS) of
            undefined -> [];
            _ -> [{?EMIT_HOOKS, {forward, self(), Tag}}]
        end,
    Hooks ++
        [
            Entry
         || {Key, _} = Entry <- get(),
            not lists:member(Key, [?EMIT_HOOKS, '$ancestors', '$initial_call', rand_seed])
        ].

-doc false.
%% Install a context captured with `capture_context/1' in the calling
%% process.
-spec adopt_context(context()) -> ok.
adopt_context(Context) ->
    lists:foreach(fun({Key, Value}) -> put(Key, Value) end, Context).
