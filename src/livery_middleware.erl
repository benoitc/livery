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

- `call(Req, Next, State) -> Resp` — invoke the middleware with
  the request, the next continuation, and the per-instance state.
""".

-include("livery.hrl").

-export([
    run/3,
    before/1,
    after_response/1,
    wrap/1
]).

-export_type([stack/0, entry/0, next/0, handler/0]).

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
