-module(livery_auth_session_ets).
-moduledoc """
The default `livery_auth_session_store`: live sessions in an ETS table
on this node.

A supervised gen_server owns one public named table; requests read and
write it directly, and the owner drops expired sessions every minute.
The table holds at most `session_max` sessions (application
environment, default 1,000,000); when it is full, new sign-ins are
refused rather than let through without a record.

The records are lost when the node restarts, so everyone signs in
again, and a session opened on one node is unknown to the others. For
a cluster, or to keep sessions over a restart, implement
`livery_auth_session_store` on shared storage.
""".
-behaviour(gen_server).
-behaviour(livery_auth_session_store).

-export([start_link/0, sweep/0]).
-export([record/2, check/2, revoke/2, revoke_user/3, revoke_provider_session/3, expire/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, livery_auth_sessions).
-define(SWEEP_INTERVAL, 60000).
-define(DEFAULT_MAX, 1000000).

-record(state, {}).
-type state() :: #state{}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Remove expired sessions now; returns how many were removed.".
-spec sweep() -> non_neg_integer().
sweep() ->
    gen_server:call(?MODULE, sweep).

%%====================================================================
%% livery_auth_session_store
%%====================================================================

-doc false.
-spec record(term(), livery_auth_session_store:entry()) -> ok | {error, full}.
record(_Arg, #{sid := Sid, iss := Iss, sub := Sub, provider_sid := PSid, expires_at := Exp}) ->
    Max = application:get_env(livery, session_max, ?DEFAULT_MAX),
    case ets:info(?TABLE, size) >= Max of
        true ->
            {error, full};
        false ->
            true = ets:insert(?TABLE, {Sid, Iss, Sub, PSid, Exp}),
            ok
    end.

-doc false.
-spec check(term(), binary()) -> valid | invalid.
check(_Arg, Sid) ->
    Now = os:system_time(second),
    case ets:lookup(?TABLE, Sid) of
        [{_, _, _, _, Exp}] when Now < Exp -> valid;
        _ -> invalid
    end.

-doc false.
-spec revoke(term(), binary()) -> ok.
revoke(_Arg, Sid) ->
    true = ets:delete(?TABLE, Sid),
    ok.

-doc false.
-spec revoke_user(term(), binary(), binary()) -> ok.
revoke_user(_Arg, Iss, Sub) ->
    _ = ets:match_delete(?TABLE, {'_', Iss, Sub, '_', '_'}),
    ok.

-doc false.
-spec revoke_provider_session(term(), binary(), binary()) -> ok.
revoke_provider_session(_Arg, Iss, PSid) ->
    _ = ets:match_delete(?TABLE, {'_', Iss, '_', PSid, '_'}),
    ok.

-doc false.
-spec expire(term(), integer()) -> non_neg_integer().
expire(_Arg, Now) ->
    ets:select_delete(?TABLE, [{{'_', '_', '_', '_', '$1'}, [{'=<', '$1', Now}], [true]}]).

%%====================================================================
%% gen_server
%%====================================================================

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
    _ = erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    {ok, #state{}}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(sweep, _From, State) ->
    {reply, expire(undefined, os:system_time(second)), State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(sweep, State) ->
    _ = expire(undefined, os:system_time(second)),
    _ = erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.
