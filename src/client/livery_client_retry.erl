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

When a retryable response carries a `Retry-After` header (delta-seconds),
that delay is honored instead of the computed backoff, capped by
`retry_after_max` ms. An HTTP-date `Retry-After` falls back to backoff.

`Opts`: `max` (default 2), `backoff` (`{BaseMs, Factor}`, default
`{200, 2.0}`), `statuses` (default `[502, 503, 504]`),
`retry_non_idempotent` (default `false`), `retry_after_max` (default
120000).
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
            timer:sleep(delay(Result, Opts, Attempt)),
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

%% Honor a Retry-After header (delta-seconds) when present, capped by
%% `retry_after_max`; otherwise fall back to exponential backoff.
delay(Result, Opts, Attempt) ->
    case retry_after_ms(Result) of
        undefined -> backoff(Opts, Attempt);
        Ms -> min(Ms, maps:get(retry_after_max, Opts, 120000))
    end.

retry_after_ms({ok, #{headers := Headers}}) ->
    case find_header(<<"retry-after">>, Headers) of
        undefined -> undefined;
        Value -> parse_delay_seconds(Value)
    end;
retry_after_ms(_Result) ->
    undefined.

%% Only the delta-seconds form is supported; an HTTP-date returns undefined
%% (the caller falls back to backoff).
parse_delay_seconds(Value) ->
    case string:to_integer(string:trim(Value)) of
        {Secs, Rest} when is_integer(Secs), Secs >= 0 ->
            case string:trim(Rest) of
                <<>> -> Secs * 1000;
                "" -> Secs * 1000;
                _ -> undefined
            end;
        _ ->
            undefined
    end.

find_header(Name, Headers) ->
    L = string:lowercase(Name),
    case lists:search(fun({K, _}) -> string:lowercase(K) =:= L end, Headers) of
        {value, {_, V}} -> V;
        false -> undefined
    end.

backoff(Opts, Attempt) ->
    {Base, Factor} = maps:get(backoff, Opts, {200, 2.0}),
    Delay = round(Base * math:pow(Factor, Attempt)),
    Delay + rand:uniform(Base).
