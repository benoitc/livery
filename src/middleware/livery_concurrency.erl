-module(livery_concurrency).
-moduledoc """
Concurrency-limit / load-shedding middleware (admission control).

Caps the number of in-flight requests. Over the limit it sheds load
immediately with `503 Service Unavailable` and never calls the handler;
at or under the limit the request proceeds, and its slot is released
once the response has been sent, streamed bodies (SSE, chunked, files)
included, or the request has failed.

Build the stack entry with the `limiter/1,2` factory, which creates the
shared counter once:

```erlang
Stack = [
    {livery_concurrency, livery_concurrency:limiter(1000)}
    %% ... handler runs only while < 1000 requests are in flight
].
```

The counter is a lock-free `atomics` cell shared across the request
processes (no extra process). A global limiter is one factory call in
the service stack; per-route limiters are independent factory calls.

Scope: a slot is held from admission until the response is fully
emitted (`livery_middleware:after_emit/1`). Outside a Livery request
worker, where that hook is not available, it is released when the
handler returns instead. The limit is approximate under a burst (a request that increments past
the limit decrements again), which is acceptable for load-shedding.
""".
-behaviour(livery_middleware).

-export([limiter/1, limiter/2, call/3]).

-export_type([state/0]).

-type state() :: #{
    ref := atomics:atomics_ref(),
    limit := non_neg_integer(),
    status := 100..599,
    body := iodata(),
    retry_after := non_neg_integer() | binary() | undefined
}.

-doc "Build a limiter stack State capping in-flight requests at `Limit`.".
-spec limiter(non_neg_integer()) -> state().
limiter(Limit) ->
    limiter(Limit, #{}).

-doc """
`limiter/1` with options.

`status` (default 503), `body` (default `<<"service unavailable">>`),
and `retry_after` (seconds as an integer, a literal binary, or
`undefined`) shape the shed response.
""".
-spec limiter(non_neg_integer(), map()) -> state().
limiter(Limit, Opts) when is_integer(Limit), Limit >= 0 ->
    #{
        ref => atomics:new(1, [{signed, false}]),
        limit => Limit,
        status => maps:get(status, Opts, 503),
        body => maps:get(body, Opts, <<"service unavailable">>),
        retry_after => maps:get(retry_after, Opts, undefined)
    }.

-doc "Admit the request if under the limit, otherwise shed with 503.".
-spec call(livery_req:req(), livery_middleware:next(), state()) ->
    livery_resp:resp().
call(Req, Next, #{ref := Ref, limit := Limit} = State) ->
    case atomics:add_get(Ref, 1, 1) of
        Count when Count > Limit ->
            atomics:sub(Ref, 1, 1),
            overloaded(State);
        _Count ->
            Release = fun() -> atomics:sub(Ref, 1, 1) end,
            case livery_middleware:after_emit(Release) of
                ok ->
                    Next(Req);
                unsupported ->
                    try
                        Next(Req)
                    after
                        Release()
                    end
            end
    end.

-spec overloaded(state()) -> livery_resp:resp().
overloaded(#{status := Status, body := Body} = State) ->
    Resp = livery_resp:text(Status, Body),
    case maps:get(retry_after, State) of
        undefined -> Resp;
        Value -> livery_resp:with_header(<<"retry-after">>, retry_value(Value), Resp)
    end.

-spec retry_value(non_neg_integer() | binary()) -> binary().
retry_value(Value) when is_integer(Value) -> integer_to_binary(Value);
retry_value(Value) when is_binary(Value) -> Value.
