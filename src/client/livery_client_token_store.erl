-module(livery_client_token_store).
-moduledoc """
Cache of OAuth access tokens for `livery_client_oauth`.

A supervised gen_server owning one public ETS table of tokens. A caller
reads the table directly and reuses a token until `Skew` seconds before
it expires. On a miss it asks this process, which runs at most one fetch
per key at a time and gives its result to every caller that asked while
it ran: when a token expires under load, the authorization server sees
one request, not one per caller.

The fetch runs in a process of its own, so a slow token endpoint holds
up only the callers waiting for that key.
""".
-behaviour(gen_server).

-export([start_link/0, get/3, invalidate/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, livery_client_tokens).

-record(state, {inflight = #{} :: #{term() => {reference(), [gen_server:from()]}}}).
-type state() :: #state{}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
A token for `Key`: the cached one if it is good for more than `Skew`
seconds, otherwise the result of `Fetch`, run once for all callers.
""".
-spec get(term(), fun(() -> {ok, map()} | {error, term()}), non_neg_integer()) ->
    {ok, map()} | {error, term()}.
get(Key, Fetch, Skew) ->
    case cached(Key, Skew) of
        {ok, _} = Hit -> Hit;
        miss -> gen_server:call(?MODULE, {fetch, Key, Fetch, Skew}, infinity)
    end.

-doc "Forget the token for `Key`, so the next `get/3` fetches a new one.".
-spec invalidate(term()) -> ok.
invalidate(Key) ->
    _ = ets:delete(?TABLE, Key),
    ok.

cached(Key, Skew) ->
    case ets:lookup(?TABLE, Key) of
        [{_, Token, undefined}] ->
            {ok, Token};
        [{_, Token, ExpiresAt}] ->
            case os:system_time(second) + Skew < ExpiresAt of
                true -> {ok, Token};
                false -> miss
            end;
        [] ->
            miss
    end.

%%====================================================================
%% gen_server
%%====================================================================

-spec init([]) -> {ok, state()}.
init([]) ->
    %% The second table holds generated DPoP keys and the nonces servers
    %% sent, for `livery_client_dpop'.
    _ = [
        ets:new(T, [named_table, public, set, {read_concurrency, true}])
     || T <- [?TABLE, livery_client_dpop:table()]
    ],
    {ok, #state{}}.

-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, term(), state()} | {noreply, state()}.
handle_call({fetch, Key, Fetch, Skew}, From, #state{inflight = In} = State) ->
    case {cached(Key, Skew), maps:find(Key, In)} of
        {{ok, _} = Hit, _} ->
            {reply, Hit, State};
        {miss, {ok, {Ref, Waiting}}} ->
            {noreply, State#state{inflight = In#{Key => {Ref, [From | Waiting]}}}};
        {miss, error} ->
            {_Pid, Ref} = spawn_monitor(fun() -> exit({token, Fetch()}) end),
            {noreply, State#state{inflight = In#{Key => {Ref, [From]}}}}
    end;
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{inflight = In} = State) ->
    case [K || {K, {R, _}} <- maps:to_list(In), R =:= Ref] of
        [Key] ->
            {Ref, Waiting} = maps:get(Key, In),
            Result = result(Key, Reason),
            _ = [gen_server:reply(From, Result) || From <- Waiting],
            {noreply, State#state{inflight = maps:remove(Key, In)}};
        [] ->
            {noreply, State}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

result(Key, {token, {ok, Token}}) ->
    true = ets:insert(?TABLE, {Key, Token, maps:get(expires_at, Token, undefined)}),
    {ok, Token};
result(_Key, {token, {error, _} = Error}) ->
    Error;
result(_Key, Reason) ->
    {error, {token_fetch_failed, Reason}}.
