-module(livery_client_concurrency).
-moduledoc """
Client layer: cap in-flight requests.

A lock-free `atomics` counter admits up to `limit` concurrent requests
through this layer; past the cap a request returns `{error, overloaded}`
without calling downstream. Add it with `livery_client:concurrency/1`.
""".

-export([limiter/1, call/3]).

-export_type([state/0]).

-opaque state() :: #{ref := atomics:atomics_ref(), limit := non_neg_integer()}.

-spec limiter(non_neg_integer()) -> state().
limiter(Limit) when is_integer(Limit), Limit >= 0 ->
    #{ref => atomics:new(1, [{signed, false}]), limit => Limit}.

-spec call(livery_client:request(), livery_client:next(), state()) ->
    {ok, livery_client:response()} | {error, term()}.
call(Req, Next, #{ref := Ref, limit := Limit}) ->
    case atomics:add_get(Ref, 1, 1) of
        Count when Count > Limit ->
            atomics:sub(Ref, 1, 1),
            {error, overloaded};
        _Count ->
            try
                Next(Req)
            after
                atomics:sub(Ref, 1, 1)
            end
    end.
