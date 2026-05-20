-module(livery_sup).
-moduledoc """
Top-level Livery supervisor.

Currently supervises `livery_req_sup`, the simple-one-for-one
parent of per-request workers. The per-listener subtrees for H3,
H2, and H1 are added by `livery_service` once Phase 4 lands.
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
        shutdown => infinity,
        type => supervisor,
        modules => [livery_req_sup]
    },
    {ok, {SupFlags, [ReqSup]}}.
