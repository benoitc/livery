-module(livery_ratelimit_store).
-moduledoc """
Owner and store for `livery_ratelimit` token buckets.

A supervised gen_server that owns one public named ETS table and reaps
idle buckets on a timer. The per-request token-bucket decision
(`check/5`) runs in the calling process directly against the public
table (lock-free CAS), so the gen_server is never on the hot path - it
only owns the table and runs cleanup. The table is `public` so requests
update buckets without serializing through the owner; this is safe
because Livery runs no untrusted in-VM code, and making it `protected`
would force every check through the owner and reintroduce exactly the
single-process bottleneck the lock-free design avoids.

Each row is `{{Name, KeyDigest}, Tokens, LastMicros, Cap, Rate}`.
`KeyDigest` is a SHA-256 of the rate-limit key, so raw bearer tokens are
never stored. `Cap`/`Rate` are denormalized so the sweep can compute
refill without the limiter config.

The table is bounded: once it holds `ratelimit_max_keys` rows
(application environment, default 1,000,000) new keys are shed
(`{deny, undefined}`) rather than inserted, so a flood of distinct keys
cannot grow the table without limit. Idle buckets are reaped every
minute, so the bound is also released as load drops.
""".
-behaviour(gen_server).

-export([start_link/0, check/5, sweep/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, livery_ratelimit).
-define(CLEANUP_INTERVAL, 60000).
-define(DEFAULT_MAX_KEYS, 1000000).

-record(state, {}).
-type state() :: #state{}.

-type result() ::
    {allow, float(), non_neg_integer() | undefined}
    | {deny, non_neg_integer() | undefined}.

-export_type([result/0]).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Token-bucket decision for `{Name, KeyDigest}`.

Returns `{allow, RemainingTokens, ResetSecs}` (a token was consumed) or
`{deny, RetryAfterSecs}`. `ResetSecs`/`RetryAfterSecs` are `undefined`
when `Rate =< 0` (no refill). Runs in the caller; lock-free.
""".
-spec check(term(), binary(), non_neg_integer(), number(), integer()) -> result().
check(Name, KeyDigest, Cap, Rate, Now) ->
    do_check({Name, KeyDigest}, Cap, Rate, Now).

-doc "Reap fully-refilled buckets now; returns the number removed.".
-spec sweep() -> non_neg_integer().
sweep() ->
    gen_server:call(?MODULE, sweep).

%%====================================================================
%% Token bucket (runs in the caller against the public table)
%%====================================================================

-spec do_check({term(), binary()}, non_neg_integer(), number(), integer()) ->
    result().
do_check(Id, Cap, Rate, Now) ->
    case ets:lookup(?TABLE, Id) of
        [] ->
            decide_new(Id, float(Cap), Now, Cap, Rate);
        [{_Id, Tokens, Last, _Cap, _Rate} = Old] ->
            Refilled = min(float(Cap), Tokens + (Now - Last) / 1.0e6 * Rate),
            decide_existing(Id, Old, Refilled, Now, Cap, Rate)
    end.

-spec decide_new({term(), binary()}, float(), integer(), non_neg_integer(), number()) ->
    result().
decide_new(Id, Tokens, Now, Cap, Rate) when Tokens >= 1.0 ->
    case at_capacity() of
        true ->
            %% Shed new keys rather than grow the table without bound.
            {deny, undefined};
        false ->
            New = {Id, Tokens - 1.0, Now, Cap, Rate},
            case ets:insert_new(?TABLE, New) of
                true -> {allow, Tokens - 1.0, reset_secs(Tokens - 1.0, Cap, Rate)};
                false -> do_check(Id, Cap, Rate, Now)
            end
    end;
decide_new(_Id, Tokens, _Now, _Cap, Rate) ->
    {deny, retry_secs(Tokens, Rate)}.

-spec at_capacity() -> boolean().
at_capacity() ->
    Max = application:get_env(livery, ratelimit_max_keys, ?DEFAULT_MAX_KEYS),
    ets:info(?TABLE, size) >= Max.

-spec decide_existing(
    {term(), binary()}, tuple(), float(), integer(), non_neg_integer(), number()
) -> result().
decide_existing(Id, Old, Refilled, Now, Cap, Rate) when Refilled >= 1.0 ->
    New = {Id, Refilled - 1.0, Now, Cap, Rate},
    case ets:select_replace(?TABLE, [{Old, [], [{const, New}]}]) of
        1 -> {allow, Refilled - 1.0, reset_secs(Refilled - 1.0, Cap, Rate)};
        0 -> do_check(Id, Cap, Rate, Now)
    end;
decide_existing(_Id, _Old, Refilled, _Now, _Cap, Rate) ->
    {deny, retry_secs(Refilled, Rate)}.

-spec reset_secs(float(), non_neg_integer(), number()) ->
    non_neg_integer() | undefined.
reset_secs(_Tokens, _Cap, Rate) when Rate =< 0 ->
    undefined;
reset_secs(Tokens, Cap, Rate) ->
    erlang:ceil((float(Cap) - Tokens) / Rate).

-spec retry_secs(float(), number()) -> non_neg_integer() | undefined.
retry_secs(_Tokens, Rate) when Rate =< 0 ->
    undefined;
retry_secs(Tokens, Rate) ->
    erlang:ceil((1.0 - Tokens) / Rate).

%%====================================================================
%% gen_server
%%====================================================================

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = ets:new(?TABLE, [
        named_table,
        public,
        set,
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    schedule_cleanup(),
    {ok, #state{}}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(sweep, _From, State) ->
    {reply, do_sweep(now_micros()), State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(cleanup, State) ->
    _ = do_sweep(now_micros()),
    schedule_cleanup(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%====================================================================
%% Cleanup
%%====================================================================

-spec schedule_cleanup() -> reference().
schedule_cleanup() ->
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup).

%% Delete only buckets that are (or by now would be) fully refilled:
%% `Tokens + (Now - Last)/1e6 * Rate >= Cap`. A fully-refilled bucket is
%% behaviorally identical to a fresh one, so this never grants extra
%% budget and never resets a hot/exhausted key (its refill is < Cap).
-spec do_sweep(integer()) -> non_neg_integer().
do_sweep(Now) ->
    NowF = float(Now),
    Spec = [
        {
            {'_', '$2', '$3', '$4', '$5'},
            [
                {'>=', {'+', '$2', {'*', {'/', {'-', NowF, '$3'}, 1.0e6}, '$5'}}, '$4'}
            ],
            [true]
        }
    ],
    ets:select_delete(?TABLE, Spec).

-spec now_micros() -> integer().
now_micros() ->
    erlang:monotonic_time(microsecond).
