-module(livery_sup).
-moduledoc """
Top-level Livery supervisor.

Supervises `livery_req_sup`, the per-request worker registry and
concurrency cap, and `livery_ratelimit_store`, the owner of the
rate-limiter ETS table. Listeners are owned by their wire libraries
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
    ReqSup = #{
        id => livery_req_sup,
        start => {livery_req_sup, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [livery_req_sup]
    },
    RateLimitStore = #{
        id => livery_ratelimit_store,
        start => {livery_ratelimit_store, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [livery_ratelimit_store]
    },
    CircuitStore = #{
        id => livery_client_circuit_store,
        start => {livery_client_circuit_store, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [livery_client_circuit_store]
    },
    {ok, {SupFlags, [ReqSup, RateLimitStore, CircuitStore]}}.
