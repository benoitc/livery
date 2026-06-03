-module(livery_req_sup).
-moduledoc """
Per-request worker registry and concurrency cap.

Adapters call `start_request/1` on every inbound request. The worker
is spawned directly in the calling process (so spawning is not
serialized through one process), then this `gen_server` is told to
monitor it. Workers are temporary: a crashed request does not
restart, the adapter sees the reset and serves the next stream.

In-flight requests are tracked in a lock-free `counters` array, not
by enumerating processes: `start_request/1` reads the count to
enforce `max_concurrent_requests` (application environment, default
10000) and answers `{error, overload}` past the cap, which the
adapter turns into a `503`. The count is incremented when a worker
is admitted and decremented when this server sees the worker's
`DOWN`, so a worker that is `kill`ed (which skips any in-process
cleanup) is still accounted for. This bounds process and memory
growth under a request flood. Operators should additionally bound
the node with `+P`/`+Q` in `vm.args` (a library cannot impose those
downstream); see `config/vm.args.example`.

The cap is a soft bound: the read-then-increment is not atomic, so a
concurrent burst may admit a few past the cap, the same as the
previous supervisor-count-based check.
""".
-behaviour(gen_server).

-export([
    start_link/0,
    start_request/1,
    in_flight/0
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

%% persistent_term key for the in-flight `counters' reference. Read on
%% the request hot path, so it lives in persistent_term (lock-free,
%% no copy) rather than this server's state.
-define(COUNTER_KEY, {?MODULE, inflight}).

-record(state, {counter :: counters:counters_ref()}).
-type state() :: #state{}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Spawn a new `livery_req_proc` worker, unless the in-flight count is at
the `max_concurrent_requests` cap, in which case return
`{error, overload}` so the adapter can shed load with a `503`.
""".
-spec start_request(livery_req_proc:args()) ->
    {ok, pid()} | {error, term()}.
start_request(Args) ->
    Ref = persistent_term:get(?COUNTER_KEY),
    Max = application:get_env(livery, max_concurrent_requests, 10000),
    case counters:get(Ref, 1) >= Max of
        true ->
            {error, overload};
        false ->
            counters:add(Ref, 1, 1),
            Pid = proc_lib:spawn(livery_req_proc, run, [Args]),
            gen_server:cast(?MODULE, {monitor, Pid}),
            {ok, Pid}
    end.

-doc "Number of requests currently in flight (0 if the app is down).".
-spec in_flight() -> non_neg_integer().
in_flight() ->
    try counters:get(persistent_term:get(?COUNTER_KEY), 1) of
        N when N > 0 -> N;
        _ -> 0
    catch
        _:_ -> 0
    end.

%%====================================================================
%% gen_server
%%====================================================================

-spec init([]) -> {ok, state()}.
init([]) ->
    Ref = counters:new(1, [write_concurrency]),
    persistent_term:put(?COUNTER_KEY, Ref),
    {ok, #state{counter = Ref}}.

-spec handle_call(term(), {pid(), term()}, state()) -> {reply, ok, state()}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%% Monitor an admitted worker so its exit (including an external kill)
%% decrements the in-flight count.
-spec handle_cast({monitor, pid()}, state()) -> {noreply, state()}.
handle_cast({monitor, Pid}, State) ->
    _ = erlang:monitor(process, Pid),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'DOWN', _Ref, process, _Pid, _Reason}, #state{counter = Ref} = State) ->
    %% One DOWN per admitted worker; balance the admission increment.
    case counters:get(Ref, 1) > 0 of
        true -> counters:sub(Ref, 1, 1);
        false -> ok
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.
