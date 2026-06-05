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
    in_flight/0,
    set_max_concurrent_requests/1
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

%% persistent_term holds `{CounterRef, Max}` for the admission hot path:
%% the in-flight `counters' reference and the `max_concurrent_requests'
%% cap. Both are read per request, so they live in persistent_term
%% (lock-free, no copy) and `Max' is resolved once at startup rather than
%% via `application:get_env/3' on every request.
-define(ADMISSION_KEY, {?MODULE, admission}).
-define(DEFAULT_MAX, 10000).

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
    {Ref, Max} = persistent_term:get(?ADMISSION_KEY),
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
    try persistent_term:get(?ADMISSION_KEY) of
        {Ref, _Max} ->
            case counters:get(Ref, 1) of
                N when N > 0 -> N;
                _ -> 0
            end
    catch
        _:_ -> 0
    end.

-doc "Update the in-flight cap at runtime (kept in persistent_term).".
-spec set_max_concurrent_requests(pos_integer()) -> ok.
set_max_concurrent_requests(Max) when is_integer(Max), Max > 0 ->
    {Ref, _Old} = persistent_term:get(?ADMISSION_KEY),
    persistent_term:put(?ADMISSION_KEY, {Ref, Max}).

%%====================================================================
%% gen_server
%%====================================================================

-spec init([]) -> {ok, state()}.
init([]) ->
    Ref = counters:new(1, [write_concurrency]),
    Max = application:get_env(livery, max_concurrent_requests, ?DEFAULT_MAX),
    persistent_term:put(?ADMISSION_KEY, {Ref, Max}),
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
