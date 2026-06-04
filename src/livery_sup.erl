-module(livery_sup).
-moduledoc """
Top-level Livery supervisor.

Supervises `livery_req_sup`, the per-request worker registry and
concurrency cap, and the ETS-table owners `livery_ratelimit_store`,
`livery_client_circuit_store`, and `livery_client_balance_store`.
Listeners are owned by their wire libraries
(`h1`/`h2`/`quic`); `livery_service` starts and stops them per
service rather than under this supervisor.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [
        worker(livery_req_sup),
        worker(livery_ratelimit_store),
        worker(livery_client_circuit_store),
        worker(livery_client_balance_store)
    ],
    {ok, {SupFlags, Children}}.

worker(Module) ->
    #{
        id => Module,
        start => {Module, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [Module]
    }.
