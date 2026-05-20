-module(livery_drain).
-moduledoc """
Graceful shutdown.

`drain/1,2` stops a running service the polite way: it stops the
listeners from accepting new connections, waits for the requests
already in flight to finish within a configurable window, then
stops the service. Returns `ok` once fully drained or
`{error, timeout}` if the window elapsed with requests still
running (the service is stopped either way).

In-flight requests are counted node-wide via the global
`livery_req_sup` — every request, on every protocol, runs in a
`livery_req_proc` child of it. A single-service node drains
exactly its own requests; on a multi-service node `drain/2` waits
for all of them.

Stopping acceptance closes the listen socket (no new connections);
it does not send GOAWAY on existing keep-alive connections.

```erlang
{ok, Pid} = livery:start_service(#{http => #{port => 8080}, router => R}),
%% ... serve ...
ok = livery:drain(Pid, #{timeout => 30000}).
```
""".

-export([drain/1, drain/2, await/0, await/1, in_flight/0]).

-export_type([opts/0]).

-type opts() :: #{
    timeout       => timeout(),
    poll_interval => non_neg_integer()
}.

-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_POLL, 100).

%%====================================================================
%% Public API
%%====================================================================

-doc "Gracefully drain and stop a service with default options.".
-spec drain(pid()) -> ok | {error, timeout}.
drain(Service) -> drain(Service, #{}).

-doc """
Gracefully drain and stop a service.

Stops accepting new connections, waits up to `timeout` (default
30s) for in-flight requests to finish, then stops the service.
The service is stopped regardless of whether the drain completed.
""".
-spec drain(pid(), opts()) -> ok | {error, timeout}.
drain(Service, Opts) when is_pid(Service) ->
    ok = livery_service:stop_accepting(Service),
    Outcome = await(Opts),
    ok = livery_service:stop(Service),
    Outcome.

-doc "Wait for in-flight requests to finish, default 30s window.".
-spec await() -> ok | {error, timeout}.
await() -> await(#{}).

-doc """
Wait until no requests are in flight, or the timeout elapses.

`Opts`: `timeout` (default 30000 ms; `infinity` allowed) and
`poll_interval` (default 100 ms).
""".
-spec await(opts()) -> ok | {error, timeout}.
await(Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Interval = maps:get(poll_interval, Opts, ?DEFAULT_POLL),
    Deadline = deadline(Timeout),
    wait_loop(Deadline, Interval).

-doc "Number of requests currently in flight (0 if the app is down).".
-spec in_flight() -> non_neg_integer().
in_flight() ->
    try
        Counts = supervisor:count_children(livery_req_sup),
        proplists:get_value(active, Counts, 0)
    catch
        _:_ -> 0
    end.

%%====================================================================
%% Internals
%%====================================================================

-spec deadline(timeout()) -> integer() | infinity.
deadline(infinity) -> infinity;
deadline(Ms) -> erlang:monotonic_time(millisecond) + Ms.

-spec wait_loop(integer() | infinity, non_neg_integer()) ->
    ok | {error, timeout}.
wait_loop(Deadline, Interval) ->
    case in_flight() of
        0 ->
            ok;
        _N ->
            case expired(Deadline) of
                true ->
                    {error, timeout};
                false ->
                    timer:sleep(Interval),
                    wait_loop(Deadline, Interval)
            end
    end.

-spec expired(integer() | infinity) -> boolean().
expired(infinity) -> false;
expired(Deadline) -> erlang:monotonic_time(millisecond) >= Deadline.
