-module(livery_auth_session_store).
-moduledoc """
Behaviour for a server-side record of live sessions.

A signed session cookie cannot be taken back: it stays valid until it
expires. Give `livery_auth_session` a `store` and each session gets an
id, recorded here, that the middleware checks on every request. Ending
the session is then removing its record, from the application
(`livery_auth_session:revoke/2`, `livery_auth_session:revoke_user/3`) or
when the provider says the user logged out (`livery_auth_backchannel`).

```erlang
Session = #{
    secret  => SessionSecret,
    max_age => 8 * 3600,                    %% required with a store
    store   => livery_auth_session_ets      %% or {Module, Arg}
}.
```

`livery_auth_session_ets` keeps the records in memory on one node. To
share them across nodes or keep them over a restart, implement these
callbacks on your own storage and pass `{Module, Arg}`; `Arg` is given
back to every callback (`undefined` when you pass a bare `Module`).

- `record(Arg, Entry) -> ok | {error, Reason}`: remember a new session.
  `Entry` has `sid`, `iss`, `sub`, `provider_sid` (the ID token's `sid`
  claim, or `undefined`) and `expires_at` (Unix seconds).
- `check(Arg, Sid) -> valid | invalid`: `valid` only for a session that
  is recorded, not revoked and not past `expires_at`.
- `revoke(Arg, Sid) -> ok`: end one session.
- `revoke_user(Arg, Iss, Sub) -> ok`: end every session of one user.
- `revoke_provider_session(Arg, Iss, ProviderSid) -> ok`: end the
  sessions opened from one session at the provider.
- `expire(Arg, Now) -> Count`: drop the records past `expires_at`.
  Livery calls it for its own store; call it from your application on
  a timer for yours, or let your storage expire rows itself.

Revoking a session that does not exist is not an error.
""".

-export([record/2, check/2, revoke/2, revoke_user/3, revoke_provider_session/3]).

-export_type([store/0, entry/0]).

-type store() :: module() | {module(), term()}.
-type entry() :: #{
    sid := binary(),
    iss := binary(),
    sub := binary(),
    provider_sid := binary() | undefined,
    expires_at := integer()
}.

-callback record(Arg :: term(), entry()) -> ok | {error, term()}.
-callback check(Arg :: term(), Sid :: binary()) -> valid | invalid.
-callback revoke(Arg :: term(), Sid :: binary()) -> ok.
-callback revoke_user(Arg :: term(), Iss :: binary(), Sub :: binary()) -> ok.
-callback revoke_provider_session(Arg :: term(), Iss :: binary(), ProviderSid :: binary()) ->
    ok.
-callback expire(Arg :: term(), Now :: integer()) -> non_neg_integer().

-doc "Record a new session in `Store`.".
-spec record(store(), entry()) -> ok | {error, term()}.
record(Store, Entry) ->
    {M, A} = split(Store),
    M:record(A, Entry).

-doc "Whether `Sid` is a live session in `Store`.".
-spec check(store(), binary()) -> valid | invalid.
check(Store, Sid) ->
    {M, A} = split(Store),
    M:check(A, Sid).

-doc "End the session `Sid`.".
-spec revoke(store(), binary()) -> ok.
revoke(Store, Sid) ->
    {M, A} = split(Store),
    M:revoke(A, Sid).

-doc "End every session of the user `Sub` at the issuer `Iss`.".
-spec revoke_user(store(), binary(), binary()) -> ok.
revoke_user(Store, Iss, Sub) ->
    {M, A} = split(Store),
    M:revoke_user(A, Iss, Sub).

-doc "End the sessions opened from the provider session `ProviderSid`.".
-spec revoke_provider_session(store(), binary(), binary()) -> ok.
revoke_provider_session(Store, Iss, ProviderSid) ->
    {M, A} = split(Store),
    M:revoke_provider_session(A, Iss, ProviderSid).

-spec split(store()) -> {module(), term()}.
split({M, A}) when is_atom(M) -> {M, A};
split(M) when is_atom(M) -> {M, undefined}.
