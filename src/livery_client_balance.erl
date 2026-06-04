-module(livery_client_balance).
-moduledoc """
Client layer: spread requests across a pool of endpoints.

Picks an endpoint from the pool named in the opts, rewrites the request
to target it, and records the outcome so a failing endpoint is ejected
and a recovering one is probed back in. Selection load and health live in
`livery_client_balance_store`. Add it with `livery_client:balance/1`.

`Opts`: `name` (required), `endpoints` (a list of base URLs, or a
`{Module, Arg}` discovery pair), `policy` (`p2c` default | `round_robin`),
`eject_after` (consecutive failures to eject, default 5), `eject_for`
(ms ejected before a half-open probe, default 10000), `fail_status`
(what counts as a failure: a `fun((status()) -> boolean())` or a list of
statuses; default treats any status `>= 500` and any `{error, _}` as a
failure).
""".

-export([call/3]).

-define(DEFAULT_EJECT_AFTER, 5).
-define(DEFAULT_EJECT_FOR, 10000).

-spec call(livery_client:request(), livery_client:next(), map()) ->
    {ok, livery_client:response()} | {error, term()}.
call(Req, Next, Opts) ->
    Name = maps:get(name, Opts),
    Endpoints = livery_client_discover:resolve(maps:get(endpoints, Opts, [])),
    ok = livery_client_balance_store:ensure(Name, Endpoints),
    Policy = maps:get(policy, Opts, p2c),
    EjectFor = maps:get(eject_for, Opts, ?DEFAULT_EJECT_FOR),
    case livery_client_balance_store:pick(Name, Policy, EjectFor) of
        {error, no_endpoint} = Error ->
            Error;
        {ok, Endpoint, Token} ->
            run(Req, Next, Opts, Name, Endpoint, Token, EjectFor)
    end.

run(Req, Next, Opts, Name, Endpoint, Token, EjectFor) ->
    EjectAfter = maps:get(eject_after, Opts, ?DEFAULT_EJECT_AFTER),
    Fail = fail_status(maps:get(fail_status, Opts, default)),
    Url = livery_client:rebase(Endpoint, maps:get(url, Req)),
    try Next(Req#{url => Url}) of
        Result ->
            Outcome = classify(Result, Fail),
            livery_client_balance_store:record(Name, Endpoint, Outcome, EjectAfter, EjectFor),
            Result
    catch
        Class:Reason:Stack ->
            livery_client_balance_store:record(Name, Endpoint, err, EjectAfter, EjectFor),
            erlang:raise(Class, Reason, Stack)
    after
        livery_client_balance_store:release(Token)
    end.

classify({error, _Reason}, _Fail) ->
    err;
classify({ok, #{status := Status}}, Fail) ->
    case Fail(Status) of
        true -> err;
        false -> ok
    end.

fail_status(default) -> fun(Status) -> Status >= 500 end;
fail_status(Fun) when is_function(Fun, 1) -> Fun;
fail_status(List) when is_list(List) -> fun(Status) -> lists:member(Status, List) end.
