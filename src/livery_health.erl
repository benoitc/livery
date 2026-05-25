-module(livery_health).
-moduledoc """
Health and readiness handlers.

`live/0` is a liveness probe - it always answers `200` `{"status":"ok"}`
(the process is up). `ready/1` is a readiness probe - it runs a list of
named checks and answers `200` when all pass, or `503` listing the
failed checks. Mount them on routes:

```erlang
R1 = livery_router:add('GET', <<"/healthz">>, livery_health:live(), #{}, R0),
R2 = livery_router:add(
    '_GET', <<"/readyz">>,
    livery_health:ready([{<<"db">>, fun () -> my_db:ping() end}]),
    #{}, R1
).
```

A check is `{Name, fun(() -> ok | {error, term()})}`; any non-`ok`
return or a raised exception counts as failed. Checks run synchronously
in the request process, so keep them fast.
""".

-export([live/0, ready/1]).

-export_type([check/0]).

-type check() :: {binary(), fun(() -> ok | {error, term()})}.

-doc "Liveness handler: always `200` `{\"status\":\"ok\"}`.".
-spec live() -> livery_middleware:handler().
live() ->
    fun(_Req) -> ok_response() end.

-doc "Readiness handler: `200` when every check passes, else `503`.".
-spec ready([check()]) -> livery_middleware:handler().
ready(Checks) ->
    fun(_Req) -> readiness(Checks) end.

-spec readiness([check()]) -> livery_resp:resp().
readiness(Checks) ->
    case [Name || {Name, Fun} <- Checks, not passes(Fun)] of
        [] ->
            ok_response();
        Failed ->
            livery_resp:json(
                503,
                json:encode(#{
                    <<"status">> => <<"unavailable">>,
                    <<"failed">> => Failed
                })
            )
    end.

-spec passes(fun(() -> ok | {error, term()})) -> boolean().
passes(Fun) ->
    try Fun() of
        ok -> true;
        _Other -> false
    catch
        _Class:_Reason -> false
    end.

-spec ok_response() -> livery_resp:resp().
ok_response() ->
    livery_resp:json(200, json:encode(#{<<"status">> => <<"ok">>})).
