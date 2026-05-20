-module(livery_req_sup).
-moduledoc """
Simple-one-for-one supervisor for `livery_req_proc` children.

Adapters call `start_request/1` on every inbound request. Children
are temporary: a crashed request does not restart, the adapter
sees the reset and serves the next stream.
""".
-behaviour(supervisor).

-export([
    start_link/0,
    start_request/1
]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc "Spawn a new `livery_req_proc` under this supervisor.".
-spec start_request(livery_req_proc:args()) ->
    {ok, pid()} | {error, term()}.
start_request(Args) ->
    supervisor:start_child(?MODULE, [Args]).

-spec init([]) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 100,
        period => 1
    },
    ChildSpec = #{
        id => livery_req_proc,
        start => {livery_req_proc, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [livery_req_proc]
    },
    {ok, {SupFlags, [ChildSpec]}}.
