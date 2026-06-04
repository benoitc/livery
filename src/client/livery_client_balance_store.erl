-module(livery_client_balance_store).
-moduledoc """
Owns the ETS table backing the client load balancers.

A `gen_server` that creates a public named table at startup; the
selection logic in `livery_client_balance` reads and writes it directly
(no per-request round trip through this process). One pool per `name`,
with one row per endpoint:

    {{ep, Name, Endpoint}, Status, Fails, Until, Inflight}

`Status` is `up | ejected`. `Inflight` is a per-endpoint `atomics` ref
holding the in-flight request count (the P2C load metric). `Until` is an
`erlang:monotonic_time(millisecond)` deadline: while ejected, the
endpoint rejoins only after `Until` has passed, and recovery is a single
probe leased with an atomic compare-and-swap so concurrent callers cannot
all probe at once. A `{{meta, Name}, RoundRobinRef}` row marks the pool's
existence (for create-once `ensure/2`) and carries the round-robin
counter.
""".
-behaviour(gen_server).

-export([start_link/0, ensure/2, add/2, remove/2, reset/1]).
-export([pick/3, record/5, release/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, ?MODULE).
-record(state, {}).
-type state() :: #state{}.
-type policy() :: p2c | round_robin.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Seed a pool from `Endpoints`, once. If the pool already exists this is a
no-op, so a lazy call on a later request never undoes a runtime
`remove/2` or re-adds a drained node. The cheap membership check runs in
the caller; only a miss talks to the gen_server.
""".
-spec ensure(term(), [binary()]) -> ok.
ensure(Name, Endpoints) ->
    case ets:member(?TABLE, {meta, Name}) of
        true -> ok;
        false -> gen_server:call(?MODULE, {ensure, Name, Endpoints})
    end.

-doc "Add an endpoint to a pool at runtime.".
-spec add(term(), binary()) -> ok.
add(Name, Endpoint) ->
    gen_server:call(?MODULE, {add, Name, Endpoint}).

-doc "Remove an endpoint from a pool at runtime.".
-spec remove(term(), binary()) -> ok.
remove(Name, Endpoint) ->
    gen_server:call(?MODULE, {remove, Name, Endpoint}).

-doc "Forget a pool entirely.".
-spec reset(term()) -> ok.
reset(Name) ->
    gen_server:call(?MODULE, {reset, Name}).

-doc """
Pick an endpoint for one request, incrementing its in-flight count.
Returns `{ok, Endpoint, Token}` (pass `Token` to `release/1` when the
request finishes) or `{error, no_endpoint}`. A recovering endpoint whose
cooldown has expired is leased for a single probe via an atomic CAS;
otherwise selection is over the healthy endpoints by `Policy`.
""".
-spec pick(term(), policy(), non_neg_integer()) ->
    {ok, binary(), atomics:atomics_ref()} | {error, no_endpoint}.
pick(Name, Policy, EjectFor) ->
    case ets:select(?TABLE, all_spec(Name)) of
        [] ->
            {error, no_endpoint};
        Rows ->
            Now = now_ms(),
            case lease_probe(Name, Rows, Now, EjectFor) of
                {ok, _Ep, _Ref} = Ok ->
                    Ok;
                none ->
                    pick_up(Name, Policy, Rows)
            end
    end.

-doc "Release the in-flight slot taken by `pick/3` (safe if removed).".
-spec release(atomics:atomics_ref()) -> ok.
release(Ref) ->
    atomics:sub(Ref, 1, 1),
    ok.

-doc """
Record a request outcome against the endpoint. `ok` resets the failure
streak and reinstates an ejected endpoint; `err` increments the streak
and ejects at `EjectAfter`, or re-ejects a failed probe. A missing row
(removed mid-flight) is a no-op.
""".
-spec record(term(), binary(), ok | err, pos_integer(), non_neg_integer()) -> ok.
record(Name, Endpoint, Outcome, EjectAfter, EjectFor) ->
    case ets:lookup(?TABLE, {ep, Name, Endpoint}) of
        [] ->
            ok;
        [{Key, Status, Fails, _Until, Ref}] ->
            apply_outcome(Key, Status, Fails, Ref, Outcome, EjectAfter, EjectFor)
    end.

%%====================================================================
%% gen_server
%%====================================================================

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set, {write_concurrency, true}]),
    {ok, #state{}}.

-spec handle_call(term(), {pid(), term()}, state()) -> {reply, ok, state()}.
handle_call({ensure, Name, Endpoints}, _From, State) ->
    case ets:member(?TABLE, {meta, Name}) of
        true ->
            ok;
        false ->
            true = ets:insert(?TABLE, {{meta, Name}, atomics:new(1, [])}),
            lists:foreach(fun(Ep) -> insert_endpoint(Name, Ep) end, Endpoints)
    end,
    {reply, ok, State};
handle_call({add, Name, Endpoint}, _From, State) ->
    case ets:member(?TABLE, {ep, Name, Endpoint}) of
        true -> ok;
        false -> insert_endpoint(Name, Endpoint)
    end,
    {reply, ok, State};
handle_call({remove, Name, Endpoint}, _From, State) ->
    true = ets:delete(?TABLE, {ep, Name, Endpoint}),
    {reply, ok, State};
handle_call({reset, Name}, _From, State) ->
    true = ets:match_delete(?TABLE, {{ep, Name, '_'}, '_', '_', '_', '_'}),
    true = ets:delete(?TABLE, {meta, Name}),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) -> {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(_Info, State) -> {noreply, State}.

%%====================================================================
%% Selection
%%====================================================================

%% {Endpoint, Status, Fails, Until, Inflight} for every endpoint in Name.
all_spec(Name) ->
    [
        {
            {{ep, Name, '$1'}, '$2', '$3', '$4', '$5'},
            [],
            [{{'$1', '$2', '$3', '$4', '$5'}}]
        }
    ].

%% Try to lease a single probe on the first expired-ejected endpoint, by
%% atomically pushing its deadline forward. The winner of the CAS owns
%% the probe; concurrent callers see 0 replacements and move on.
lease_probe(_Name, [], _Now, _EjectFor) ->
    none;
lease_probe(Name, [{Ep, ejected, _F, Until, Ref} | Rest], Now, EjectFor) when Until =< Now ->
    case cas_lease(Name, Ep, Now, EjectFor) of
        1 ->
            atomics:add(Ref, 1, 1),
            {ok, Ep, Ref};
        0 ->
            lease_probe(Name, Rest, Now, EjectFor)
    end;
lease_probe(Name, [_Row | Rest], Now, EjectFor) ->
    lease_probe(Name, Rest, Now, EjectFor).

%% Bind the whole row in vars and keep the key untouched ('$1'): a bare
%% tuple in a match-spec body is read as an action, so a tuple Name cannot
%% be reconstructed there. {const, Key} injects it literally in the guard.
cas_lease(Name, Ep, Now, EjectFor) ->
    Key = {ep, Name, Ep},
    NewUntil = Now + EjectFor,
    ets:select_replace(?TABLE, [
        {
            {'$1', ejected, '$2', '$3', '$4'},
            [{'=:=', '$1', {const, Key}}, {'=<', '$3', Now}],
            [{{'$1', ejected, '$2', NewUntil, '$4'}}]
        }
    ]).

pick_up(Name, Policy, Rows) ->
    case [{Ep, Ref, load(Ref)} || {Ep, up, _F, _U, Ref} <- Rows] of
        [] ->
            {error, no_endpoint};
        Ups ->
            {Ep, Ref} = choose(Policy, Name, Ups),
            atomics:add(Ref, 1, 1),
            {ok, Ep, Ref}
    end.

choose(round_robin, Name, Ups) ->
    [{_, RRRef}] = ets:lookup(?TABLE, {meta, Name}),
    Idx = atomics:add_get(RRRef, 1, 1),
    {Ep, Ref, _Load} = lists:nth((Idx rem length(Ups)) + 1, Ups),
    {Ep, Ref};
choose(_P2c, _Name, [{Ep, Ref, _Load}]) ->
    {Ep, Ref};
choose(_P2c, _Name, Ups) ->
    N = length(Ups),
    I = rand:uniform(N),
    J0 = rand:uniform(N - 1),
    J =
        case J0 >= I of
            true -> J0 + 1;
            false -> J0
        end,
    {Ep, Ref, _} = lower_load(lists:nth(I, Ups), lists:nth(J, Ups)),
    {Ep, Ref}.

lower_load({_, _, La} = A, {_, _, Lb} = B) ->
    case La =< Lb of
        true -> A;
        false -> B
    end.

load(Ref) -> atomics:get(Ref, 1).

%%====================================================================
%% Outcome accounting
%%====================================================================

apply_outcome(Key, _Status, _Fails, Ref, ok, _EjectAfter, _EjectFor) ->
    true = ets:insert(?TABLE, {Key, up, 0, 0, Ref}),
    ok;
apply_outcome(Key, up, Fails, Ref, err, EjectAfter, EjectFor) ->
    case Fails + 1 >= EjectAfter of
        true -> true = ets:insert(?TABLE, {Key, ejected, 0, now_ms() + EjectFor, Ref});
        false -> true = ets:insert(?TABLE, {Key, up, Fails + 1, 0, Ref})
    end,
    ok;
apply_outcome(Key, ejected, Fails, Ref, err, _EjectAfter, EjectFor) ->
    true = ets:insert(?TABLE, {Key, ejected, Fails, now_ms() + EjectFor, Ref}),
    ok.

%%====================================================================
%% Internals
%%====================================================================

insert_endpoint(Name, Endpoint) ->
    true = ets:insert(?TABLE, {{ep, Name, Endpoint}, up, 0, 0, atomics:new(1, [])}),
    ok.

now_ms() ->
    erlang:monotonic_time(millisecond).
