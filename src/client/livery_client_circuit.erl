-module(livery_client_circuit).
-moduledoc """
Client layer: a circuit breaker.

Tracks the recent failure ratio for a named target. While the circuit is
closed, requests pass and outcomes are tallied over a tumbling `window`;
once the failure ratio reaches `trip`, the circuit opens and further
requests fail fast with `{error, circuit_open}`. After `cooldown` ms the
breaker half-opens to let one probe through, closing again on success or
re-opening on failure. Add it with `livery_client:circuit_breaker/1`.

`Opts`: `name` (required), `window` (default 20), `trip` (default 0.5),
`cooldown` ms (default 5000).
""".

-export([call/3]).

-spec call(livery_client:request(), livery_client:next(), map()) ->
    {ok, livery_client:response()} | {error, term()}.
call(Req, Next, Opts) ->
    Name = maps:get(name, Opts),
    Cooldown = maps:get(cooldown, Opts, 5000),
    case livery_client_circuit_store:allow(Name, Cooldown) of
        deny ->
            {error, circuit_open};
        allow ->
            Result = Next(Req),
            Window = maps:get(window, Opts, 20),
            Trip = maps:get(trip, Opts, 0.5),
            livery_client_circuit_store:record(Name, outcome(Result), Window, Trip),
            Result
    end.

outcome({ok, _Response}) -> ok;
outcome({error, _Reason}) -> err.
