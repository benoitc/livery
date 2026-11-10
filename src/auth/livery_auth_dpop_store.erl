-module(livery_auth_dpop_store).
-moduledoc """
Single-use store for DPoP proofs (RFC 9449 section 11.1) and passkey
challenges (`livery_auth_passkey`).

A supervised gen_server that owns one public named ETS table of proof
identifiers and drops them once they are too old to be accepted
anyway. `claim/2` runs in the caller with `ets:insert_new/2`, so the
first request to present a proof wins and any later one is refused,
without going through the owner.

Each row is `{KeyDigest, ExpiresAt}`; the digest is a SHA-256 of the
proof's key thumbprint and `jti`, so nothing a client sent is stored as
is. The table holds at most `dpop_max_proofs` rows (application
environment, default 1,000,000). When it is full, new proofs are
refused rather than let through unchecked; expired rows are removed
every 10 seconds.

Deviations: the store is local to the node. In a cluster, pass
`dpop_replay` to the middleware to use a shared store. See AGENTS.md,
Known deviations.
""".
-behaviour(gen_server).

-export([start_link/0, claim/2, sweep/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, livery_auth_dpop_proofs).
-define(SWEEP_INTERVAL, 10000).
-define(DEFAULT_MAX, 1000000).

-record(state, {}).
-type state() :: #state{}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Record `Key` until `ExpiresAt` (Unix seconds). `fresh` when this is the
first time it is seen, `replayed` when it was seen before or the store
is full.
""".
-spec claim(binary(), integer()) -> fresh | replayed.
claim(Key, ExpiresAt) ->
    Max = application:get_env(livery, dpop_max_proofs, ?DEFAULT_MAX),
    case ets:info(?TABLE, size) >= Max of
        true ->
            replayed;
        false ->
            case ets:insert_new(?TABLE, {crypto:hash(sha256, Key), ExpiresAt}) of
                true -> fresh;
                false -> replayed
            end
    end.

-doc "Remove expired rows now; returns how many were removed.".
-spec sweep() -> non_neg_integer().
sweep() ->
    gen_server:call(?MODULE, sweep).

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set, {write_concurrency, true}]),
    _ = erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    {ok, #state{}}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(sweep, _From, State) ->
    {reply, do_sweep(), State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(sweep, State) ->
    _ = do_sweep(),
    _ = erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

do_sweep() ->
    Now = os:system_time(second),
    ets:select_delete(?TABLE, [{{'_', '$1'}, [{'<', '$1', Now}], [true]}]).
