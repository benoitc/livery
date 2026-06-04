-module(livery_client_retry).
-moduledoc """
Client layer: retry failed requests with exponential backoff.

Retries on transport errors and on the configured retryable status codes
(502/503/504 by default), up to `max` extra attempts, sleeping
`Base * Factor^Attempt` ms plus jitter between tries. Only idempotent
methods (GET/HEAD/PUT/DELETE/OPTIONS) are retried unless
`retry_non_idempotent => true`, and a request with a one-shot streaming
body is never retried (the producer cannot be replayed). Add it with
`livery_client:retry/1`.

`Opts`: `max` (default 2), `backoff` (`{BaseMs, Factor}`, default
`{200, 2.0}`), `statuses` (default `[502, 503, 504]`),
`retry_non_idempotent` (default `false`).
""".

-export([call/3]).

-spec call(livery_client:request(), livery_client:next(), map()) ->
    {ok, livery_client:response()} | {error, term()}.
call(Req, Next, Opts) ->
    Max = maps:get(max, Opts, 2),
    loop(Req, Next, Opts, Max, 0).

loop(Req, Next, Opts, Max, Attempt) ->
    Result = Next(Req),
    case retry(Result, Req, Opts, Attempt, Max) of
        true ->
            timer:sleep(backoff(Opts, Attempt)),
            loop(Req, Next, Opts, Max, Attempt + 1);
        false ->
            Result
    end.

retry(Result, Req, Opts, Attempt, Max) ->
    Attempt < Max andalso
        replayable(Req, Opts) andalso
        retryable(Result, Opts).

%% A streaming request body cannot be replayed, so do not retry it.
replayable(Req, Opts) ->
    case maps:get(body, Req, empty) of
        {stream, _} -> false;
        _ -> idempotent(maps:get(method, Req), Opts)
    end.

idempotent(_Method, #{retry_non_idempotent := true}) ->
    true;
idempotent(Method, _Opts) ->
    lists:member(
        normalize(Method),
        [<<"get">>, <<"head">>, <<"put">>, <<"delete">>, <<"options">>]
    ).

normalize(M) when is_atom(M) -> normalize(atom_to_binary(M, utf8));
normalize(M) when is_binary(M) -> string:lowercase(M).

retryable({error, _Reason}, _Opts) ->
    true;
retryable({ok, #{status := Status}}, Opts) ->
    lists:member(Status, maps:get(statuses, Opts, [502, 503, 504])).

backoff(Opts, Attempt) ->
    {Base, Factor} = maps:get(backoff, Opts, {200, 2.0}),
    Delay = round(Base * math:pow(Factor, Attempt)),
    Delay + rand:uniform(Base).
