-module(livery_req_sup).
-moduledoc """
Simple-one-for-one supervisor for `livery_req_proc` children.

Adapters call `start_request/1` on every inbound request. Children
are temporary: a crashed request does not restart, the adapter
sees the reset and serves the next stream.

The supervisor caps concurrent in-flight requests: `start_request/1`
checks the live child count against `max_concurrent_requests`
(application environment, default 10000) and returns `{error, overload}`
past the cap, which the adapter answers with `503`. This bounds process
and memory growth under a connection/request flood. (OTP supervisors
have no built-in child ceiling, so the check is explicit; the count is
accurate even when a worker is `kill`ed.) Operators should additionally
bound the node with `+P`/`+Q` in `vm.args` (a library cannot impose those
downstream); see `config/vm.args.example`.
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

-doc """
Spawn a new `livery_req_proc` under this supervisor, unless the live
child count is at the `max_concurrent_requests` cap, in which case
return `{error, overload}` so the adapter can shed load with a `503`.
""".
-spec start_request(livery_req_proc:args()) ->
    {ok, pid()} | {error, term()}.
start_request(Args) ->
    Max = application:get_env(livery, max_concurrent_requests, 10000),
    Counts = supervisor:count_children(?MODULE),
    case proplists:get_value(active, Counts) >= Max of
        true -> {error, overload};
        false -> supervisor:start_child(?MODULE, [Args])
    end.

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
