-module(livery_auth_passkey).
-moduledoc """
Passkey routes: register a passkey, sign in with one.

`routes/1` returns four JSON routes (POST) for `livery_router:compile/1`,
under `prefix` (default `/passkeys`):

- `register/options`, `register`: add a passkey to the signed-in user;
- `login/options`, `login`: sign in with a passkey, without a username
  (the browser offers the passkeys it has for the site), and end in a
  `livery_auth_session` cookie.

The challenge travels in a short-lived signed cookie, scoped to the
prefix and `SameSite=Strict`, and each challenge is accepted once
(claimed in `livery_auth_dpop_store`, or `challenge_replay` in a
cluster). The checks themselves are `livery_auth_webauthn`.

Livery stores nothing; the application does, through these callbacks:

- `current_user => fun((Req) -> User | undefined)`: who is signed in,
  for registration. `User` is a map with `id` (a stable opaque handle,
  at most 64 bytes, not an email), `name` and optionally `display_name`.
- `credentials_for_user => fun((User) -> [CredentialId])`: passkeys the
  user already has, so the browser does not make a second one.
- `store_credential => fun((User, Credential) -> ok | {error, term()})`:
  keep a new passkey. Store the whole map; it holds `user_handle`.
- `find_credential => fun((CredentialId) -> {ok, User, Credential} | not_found)`.
- `update_credential => fun((CredentialId, Updates) -> ok)`: save the new
  `sign_count` and `backup_state` after each sign-in.
- `on_login => fun((User, Credential) -> map())`: what goes in the
  session (default `#{<<"sub">> => UserId}`).

Other options: `rp_id`, `rp_name`, `origins` and `session` (the
`livery_auth_session` options, with `secret`) required;
`user_verification` and `resident_key` (`preferred` by default),
`attestation_roots`, `allow_unattested`, `challenge_replay`, `prefix`.
""".

-export([routes/1]).

-define(CHALLENGE_AGE, 120).
-define(MAX_BODY, 65536).

-doc "The four passkey routes, for `livery_router:compile/1`.".
-spec routes(map()) -> [{binary(), binary(), livery_middleware:handler()}].
routes(Opts) ->
    P = maps:get(prefix, Opts, <<"/passkeys">>),
    With = fun(F) -> fun(Req) -> F(Req, Opts) end end,
    [
        {<<"POST">>, <<P/binary, "/register/options">>, With(fun register_options/2)},
        {<<"POST">>, <<P/binary, "/register">>, With(fun register_finish/2)},
        {<<"POST">>, <<P/binary, "/login/options">>, With(fun login_options/2)},
        {<<"POST">>, <<P/binary, "/login">>, With(fun login_finish/2)}
    ].

%%====================================================================
%% Registration
%%====================================================================

register_options(Req, Opts) ->
    case call(current_user, [Req], Opts) of
        #{id := UserId} = User ->
            Exclude = call(credentials_for_user, [User], Opts),
            WebOpts = (webauthn_opts(Opts))#{exclude => Exclude, attestation => attestation(Opts)},
            {Challenge, Options} = livery_auth_webauthn:creation_options(User, WebOpts),
            with_challenge(Options, register, Challenge, UserId, Opts);
        _ ->
            json(401, #{<<"error">> => <<"sign_in_first">>}, [], Opts)
    end.

register_finish(Req, Opts) ->
    maybe
        #{id := UserId} = User ?= call(current_user, [Req], Opts),
        {ok, Challenge} ?= challenge(Req, register, UserId, Opts),
        {ok, Body} ?= body(Req),
        {ok, Cred0} ?= livery_auth_webauthn:verify_registration(Body, expected(Challenge, Opts)),
        ok ?= once(Challenge, Opts),
        Cred = Cred0#{user_handle => UserId},
        ok ?= call(store_credential, [User, Cred], Opts),
        json(201, #{<<"id">> => b64(maps:get(id, Cred))}, [], Opts)
    else
        undefined -> json(401, #{<<"error">> => <<"sign_in_first">>}, [], Opts);
        Other -> refused(Other, Opts)
    end.

attestation(#{attestation_roots := [_ | _]}) -> direct;
attestation(_Opts) -> none.

%%====================================================================
%% Sign-in
%%====================================================================

login_options(_Req, Opts) ->
    {Challenge, Options} = livery_auth_webauthn:request_options(webauthn_opts(Opts)),
    with_challenge(Options, login, Challenge, <<>>, Opts).

login_finish(Req, Opts) ->
    maybe
        {ok, Challenge} ?= challenge(Req, login, <<>>, Opts),
        {ok, #{<<"rawId">> := RawId} = Body} ?= body(Req),
        {ok, CredId} ?= decode_id(RawId),
        {ok, User, Cred} ?= call(find_credential, [CredId], Opts),
        {ok, Updates} ?=
            livery_auth_webauthn:verify_authentication(Body, Cred, expected(Challenge, Opts)),
        ok ?= once(Challenge, Opts),
        ok ?= call(update_credential, [CredId, Updates], Opts),
        signed_in(User, maps:merge(Cred, Updates), Opts)
    else
        not_found -> refused({error, unknown_credential}, Opts);
        Other -> refused(Other, Opts)
    end.

signed_in(User, Cred, Opts) ->
    OnLogin = maps:get(on_login, Opts, fun(#{id := Id}, _C) -> #{<<"sub">> => b64(Id)} end),
    Session = maps:get(session, Opts),
    Value = livery_auth_session:sign(OnLogin(User, Cred), Session),
    json(200, #{<<"ok">> => true}, [livery_auth_session:set_cookie_header(Value, Session)], Opts).

%%====================================================================
%% Challenge cookie
%%====================================================================

with_challenge(Options, Ceremony, Challenge, UserId, Opts) ->
    Saved = #{
        <<"c">> => atom_to_binary(Ceremony),
        <<"challenge">> => b64(Challenge),
        <<"user">> => b64(UserId)
    },
    Cookie = livery_auth_session:set_cookie_header(
        livery_auth_session:sign(Saved, signing(Opts)), cookie_opts(Opts)
    ),
    livery_resp:json(200, [Cookie], json:encode(Options)).

challenge(Req, Ceremony, UserId, Opts) ->
    Want = #{<<"c">> => atom_to_binary(Ceremony), <<"user">> => b64(UserId)},
    case livery_ext:cookie(cookie_name(Opts), Req) of
        undefined ->
            {error, no_challenge};
        Value ->
            case livery_auth_session:verify(Value, signing(Opts)) of
                {ok, #{<<"challenge">> := C} = Saved} ->
                    case maps:with([<<"c">>, <<"user">>], Saved) of
                        Want -> decode_id(C);
                        _ -> {error, no_challenge}
                    end;
                _ ->
                    {error, no_challenge}
            end
    end.

%% Each challenge is good for one response (WebAuthn L3 13.4.3).
once(Challenge, Opts) ->
    Claim = maps:get(challenge_replay, Opts, fun livery_auth_dpop_store:claim/2),
    case Claim(<<"passkey", 0, Challenge/binary>>, os:system_time(second) + ?CHALLENGE_AGE) of
        fresh -> ok;
        replayed -> {error, challenge_reused}
    end.

%% Finishing a ceremony, either way, drops its challenge cookie.
json(Status, Body, Cookies, Opts) ->
    Clear = livery_auth_session:clear_cookie_header(cookie_opts(Opts)),
    livery_resp:json(Status, [Clear | Cookies], json:encode(Body)).

cookie_opts(Opts) ->
    #{
        name => cookie_name(Opts),
        path => maps:get(prefix, Opts, <<"/passkeys">>),
        max_age => ?CHALLENGE_AGE,
        same_site => <<"Strict">>,
        secure => maps:get(secure, maps:get(session, Opts), true),
        http_only => true
    }.

cookie_name(Opts) ->
    <<(maps:get(name, maps:get(session, Opts), <<"session">>))/binary, "_passkey">>.

signing(Opts) ->
    #{secret => maps:get(secret, maps:get(session, Opts)), max_age => ?CHALLENGE_AGE}.

%%====================================================================
%% Helpers
%%====================================================================

webauthn_opts(Opts) ->
    maps:with([rp_id, rp_name, user_verification, resident_key, timeout, algorithms], Opts).

expected(Challenge, Opts) ->
    Keys = [
        rp_id,
        origins,
        user_verification,
        attestation_roots,
        allow_unattested,
        allow_cross_origin,
        algorithms
    ],
    (maps:with(Keys, Opts))#{challenge => Challenge}.

call(Name, Args, Opts) ->
    apply(maps:get(Name, Opts), Args).

body(Req) ->
    case raw_body(Req) of
        {ok, Bin} ->
            try json:decode(Bin) of
                #{} = Map -> {ok, Map};
                _ -> {error, bad_body}
            catch
                _:_ -> {error, bad_body}
            end;
        Error ->
            Error
    end.

raw_body(Req) ->
    case livery_req:body(Req) of
        {buffered, B} ->
            {ok, iolist_to_binary(B)};
        {stream, Reader} ->
            case livery_body:read_all(Reader, 5000, ?MAX_BODY) of
                {ok, B, _} -> {ok, B};
                {error, _, _} -> {error, bad_body}
            end;
        _ ->
            {error, bad_body}
    end.

decode_id(B64) when is_binary(B64) ->
    case livery_auth_jose:b64url(B64) of
        {ok, Bin} -> {ok, Bin};
        error -> {error, bad_body}
    end;
decode_id(_) ->
    {error, bad_body}.

%% A refusal gives a short code for the page to act on, nothing more.
refused({error, Reason}, Opts) -> json(400, #{<<"error">> => reason(Reason)}, [], Opts);
refused(_Other, Opts) -> json(400, #{<<"error">> => <<"invalid">>}, [], Opts).

reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
reason({Reason, _}) when is_atom(Reason) -> atom_to_binary(Reason);
reason(_) -> <<"invalid">>.

b64(B) -> base64:encode(B, #{mode => urlsafe, padding => false}).
