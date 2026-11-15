# How to end sessions from the server

A signed session cookie stays valid until it expires: once you have
handed it out, you cannot take it back. Give `livery_auth_session` a
session store and you can. Each session gets an id that the middleware
checks on every request, so you can sign a user out of every device,
for example when you deactivate their account, and you can let the
identity provider end sessions when the user logs out there (OpenID
Connect Back-Channel Logout 1.0). You need this as soon as "signed out"
has to mean signed out now, not when the cookie runs out.

## Turn on the store

Add `store` and `max_age` to the session options you already pass to
`livery_auth_login`, `livery_auth_passkey` and the middleware:

```erlang
Session = #{
    secret  => SessionSecret,
    max_age => 8 * 3600,
    store   => livery_auth_session_ets
},
Login = #{
    provider     => Provider,
    client_id    => <<"my-app">>,
    client_secret => <<"s3cret">>,
    redirect_uri => <<"https://app.example/auth/callback">>,
    session      => Session
},
Router = livery_router:compile(livery_auth_login:routes(Login) ++ AppRoutes),
Stack = [{livery_auth_session, Session}].
```

From now on, signing in records the session, `/logout` ends it, and a
request whose session was ended gets `401` and a cookie that clears
itself.

If you sign people in some other way, open the session with `create/3`
instead of `sign/2`, saying who it belongs to:

```erlang
{ok, Value} = livery_auth_session:create(
    #{<<"sub">> => UserId},
    #{iss => <<"my-app">>, sub => UserId},
    Session
),
{K, V} = livery_auth_session:set_cookie_header(Value, Session).
```

## Sign a user out everywhere

Call `revoke_user/3` with the issuer and the subject the session was
opened for. For an OpenID Connect sign-in, these are the `iss` and `sub`
of the ID token:

```erlang
deactivate(Iss, Sub) ->
    ok = livery_auth_session:revoke_user(Iss, Sub, Session).
```

Their next request, on any device, is refused. To end one session
only, call `livery_auth_session:revoke(Sid, Session)` with the
`<<"livery_sid">>` value of that session's payload.

## Follow logouts at the provider

Set `backchannel_logout_path` and register that URL with your provider
as the client's back-channel logout URI:

```erlang
Login = #{
    %% ... as above
    backchannel_logout_path => <<"/auth/backchannel-logout">>,
    on_logout => fun(_Iss, Sub, _Sid) -> softphone:hang_up(Sub) end
}.
```

`routes/1` adds a POST route there. When the user logs out at the
provider, the provider sends it a signed logout token; Livery checks it
and ends the session the token names (or, when it names only the user,
all of their sessions from that provider). `on_logout` is optional: use
it to close what else the user has open. Its `Sub` or `Sid` is
`undefined` when the token does not carry it.

The route accepts bodies up to 16 KiB and, per peer address, 100
requests in a burst and 10 a second. Pass `backchannel_rate` with your
own `livery_ratelimit` state, or `false`, to change that.

Two options tighten the checks when your provider supports them:

```erlang
backchannel_session_required => true,  %% refuse tokens without a sid
backchannel_require_typ      => true   %% refuse tokens not typed logout+jwt
```

## Run on several nodes

`livery_auth_session_ets` keeps sessions in memory on one node: a
restart signs everyone out, and a session opened on one node is unknown
to the others. On a cluster, implement `livery_auth_session_store` on
storage every node shares and pass it as `{Module, Arg}`:

```erlang
-module(my_session_store).
-behaviour(livery_auth_session_store).
-export([record/2, check/2, revoke/2, revoke_user/3,
         revoke_provider_session/3, expire/2]).

record(Db, #{sid := Sid} = Entry) -> my_db:put(Db, Sid, Entry).
check(Db, Sid) ->
    case my_db:get(Db, Sid) of
        {ok, #{expires_at := Exp}} ->
            case os:system_time(second) < Exp of
                true -> valid;
                false -> invalid
            end;
        not_found -> invalid
    end.
revoke(Db, Sid) -> my_db:delete(Db, Sid).
revoke_user(Db, Iss, Sub) -> my_db:delete_where(Db, #{iss => Iss, sub => Sub}).
revoke_provider_session(Db, Iss, PSid) ->
    my_db:delete_where(Db, #{iss => Iss, provider_sid => PSid}).
expire(Db, Now) -> my_db:delete_older(Db, expires_at, Now).
```

```erlang
Session = #{secret => SessionSecret, max_age => 8 * 3600,
            store => {my_session_store, Db}}.
```

Livery also remembers each logout token it accepts, so the same one is
not used twice. That record is per node too; pass
`logout_replay => fun((Key, ExpiresAt) -> fresh | replayed)` to share it.

## Notes

- Turning the store on signs everyone out once: cookies signed before
  have no session id, and are refused.
- `max_age` is required with a store; it is how long a session lives.
- A store that refuses a new session (the default one holds at most
  `session_max` sessions, 1,000,000 unless you set the application
  variable) makes the sign-in answer `503`.
- Passkey sessions are recorded with your `rp_id` as the issuer and the
  base64url user id as the subject.
- Front-channel logout is not supported.

## See also

- Reference: `livery_auth_session`, `livery_auth_session_store`,
  `livery_auth_backchannel`, `livery_auth_login`
- Guides: [Sign users in with OpenID Connect](sign-in-with-openid-connect.md),
  [Use signed session cookies](session-cookies.md)
