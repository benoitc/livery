-module(livery_client_circuit_store).
-moduledoc """
Owns the ETS table backing the client circuit breakers.

A `gen_server` that creates a public named table at startup and clears it
on shutdown; the decision logic in `livery_client_circuit` reads and
writes the table directly (no per-request round trip through this
process). One row per breaker name: `{Name, Status, Fails, Total,
OpenedAtMs}` where `Status` is `closed | open | half_open`.
""".
-behaviour(gen_server).

-export([start_link/0, allow/2, record/4, reset/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, ?MODULE).
-record(state, {}).
-type state() :: #state{}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "May a request pass? Half-opens an expired-cooldown breaker to probe.".
-spec allow(term(), non_neg_integer()) -> allow | deny.
allow(Name, Cooldown) ->
    case lookup(Name) of
        {open, _F, _T, OpenedAt} ->
            case now_ms() - OpenedAt >= Cooldown of
                true ->
                    true = ets:insert(?TABLE, {Name, half_open, 0, 0, now_ms()}),
                    allow;
                false ->
                    deny
            end;
        _ ->
            allow
    end.

-doc "Record a request outcome and update the breaker state.".
-spec record(term(), ok | err, pos_integer(), float()) -> ok.
record(Name, Outcome, Window, Trip) ->
    case lookup(Name) of
        {half_open, _F, _T, _O} when Outcome =:= ok ->
            put_row(Name, closed, 0, 0, 0);
        {half_open, _F, _T, _O} ->
            put_row(Name, open, 0, 0, now_ms());
        {open, _F, _T, _O} ->
            ok;
        {S, F, T, _O} when S =:= closed ->
            F1 = F + fail(Outcome),
            T1 = T + 1,
            evaluate(Name, F1, T1, Window, Trip)
    end.

-doc "Forget a breaker's state.".
-spec reset(term()) -> ok.
reset(Name) ->
    true = ets:delete(?TABLE, Name),
    ok.

%%====================================================================
%% gen_server
%%====================================================================

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set, {write_concurrency, true}]),
    {ok, #state{}}.

-spec handle_call(term(), {pid(), term()}, state()) -> {reply, ok, state()}.
handle_call(_Request, _From, State) -> {reply, ok, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) -> {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(_Info, State) -> {noreply, State}.

%%====================================================================
%% Internals
%%====================================================================

lookup(Name) ->
    case ets:lookup(?TABLE, Name) of
        [{_, S, F, T, O}] -> {S, F, T, O};
        [] -> {closed, 0, 0, 0}
    end.

evaluate(Name, Fails, Total, Window, Trip) when Total >= Window ->
    case Fails / Total >= Trip of
        true -> put_row(Name, open, 0, 0, now_ms());
        false -> put_row(Name, closed, 0, 0, 0)
    end;
evaluate(Name, Fails, Total, _Window, _Trip) ->
    put_row(Name, closed, Fails, Total, 0).

put_row(Name, Status, Fails, Total, OpenedAt) ->
    true = ets:insert(?TABLE, {Name, Status, Fails, Total, OpenedAt}),
    ok.

fail(ok) -> 0;
fail(err) -> 1.

now_ms() ->
    erlang:monotonic_time(millisecond).
