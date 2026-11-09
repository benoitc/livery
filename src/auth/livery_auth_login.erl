-module(livery_auth_login).
-moduledoc """
Sign users in with OpenID Connect (authorization code flow with PKCE).

`routes/1` returns the three routes a web app needs: a login route that
sends the browser to the identity provider, the callback the provider
sends it back to, and a logout route. After a successful sign-in the
user's identity is kept in a signed session cookie that
`livery_auth_session` reads on later requests.

```erlang
{ok, Provider} = livery_auth_oidc:discover(<<"https://accounts.example">>),
Login = #{
    provider      => Provider,
    client_id     => <<"my-app">>,
    client_secret => <<"s3cret">>,
    redirect_uri  => <<"https://app.example/auth/callback">>,
    scope         => [<<"openid">>, <<"email">>],
    session       => #{secret => SessionSecret, max_age => 8 * 3600}
},
Router = livery_router:compile(livery_auth_login:routes(Login) ++ AppRoutes).
```

What it checks, so a forged or replayed answer is refused:

- `state` (RFC 6749 10.12) and a PKCE verifier (RFC 7636, S256), kept
  in a short-lived signed cookie bound to the browser;
- the provider's `iss` in the callback when it sends one, and its
  presence when the provider says it always does (RFC 9207);
- the ID token (OpenID Connect Core 3.1.3.7): signature with the
  provider's keys, `iss`, `aud` containing the client id, `azp` when
  present, `exp`, `iat`, the `nonce` sent at login, and `at_hash` when
  present.

Options: `provider` (discovery metadata, required), `client_id`,
`redirect_uri` and `session` (the `livery_auth_session` options, with
`secret`) required; `scope` (`openid` is always added), the token
client options (`client_auth`, `client_secret`, `private_key`, ...),
`login_path` (default `/login`), `logout_path` (default `/logout`),
`after_logout` (default `/`), `provider_logout` (default `true`),
`post_logout_redirect_uri`, `keep_id_token` (default `false`), `params` (extra authorization request
parameters, such as `prompt`), `on_login => fun((Claims, Token) -> map())`
to choose what goes in the session (default `sub`, `iss`, `name`,
`email`), `keys` or `fetch` to supply the provider's keys, `leeway`.

A `return_to` query parameter on the login route says where to go
after signing in; only a local path is followed, anything else goes to
`/`, so the login route cannot be used as an open redirect.

Logging out clears the session cookie. When the provider publishes an
`end_session_endpoint`, the browser is then sent there to end the
session at the provider too (OpenID Connect RP-Initiated Logout 1.0),
with `client_id`, `post_logout_redirect_uri` when you set it, and the
ID token as `id_token_hint` when the session holds one. Without the
hint the provider asks the user to confirm; set `keep_id_token => true`
to keep the ID token in the session (it makes the cookie larger), or
`provider_logout => false` to end the session in this application
only. Being told about a logout that happened at the provider
(back-channel or front-channel logout) is not supported: sessions are
cookies, with nothing on the server to end.

Deviations: `at_hash` is not checked for Ed448 ID tokens, since OpenID
Connect does not say which hash goes with that curve. See AGENTS.md,
Known deviations.
""".

-export([routes/1, login/1, callback/1, logout/1]).

-define(STATE_COOKIE_AGE, 600).

-doc "The login, callback and logout routes, for `livery_router:compile/1`.".
-spec routes(map()) -> [{binary(), binary(), livery_middleware:handler()}].
routes(Opts) ->
    Logout = logout(Opts),
    [
        {<<"GET">>, maps:get(login_path, Opts, <<"/login">>), login(Opts)},
        {<<"GET">>, callback_path(Opts), callback(Opts)},
        {<<"GET">>, logout_path(Opts), Logout},
        {<<"POST">>, logout_path(Opts), Logout}
    ].

%%====================================================================
%% Login
%%====================================================================

-doc "The handler that starts a sign-in.".
-spec login(map()) -> livery_middleware:handler().
login(Opts) ->
    fun(Req) ->
        State = random(),
        Nonce = random(),
        Verifier = random(),
        StepUp = requested(Req, Opts),
        Saved = maps:merge(StepUp, #{
            <<"state">> => State,
            <<"nonce">> => Nonce,
            <<"verifier">> => Verifier,
            <<"return_to">> => return_to(livery_ext:query(<<"return_to">>, Req))
        }),
        Params = authorization_params(State, Nonce, Verifier, StepUp, Opts),
        case authorization_url(Params, Opts) of
            {ok, Url} ->
                Cookie = state_cookie(
                    livery_auth_session:sign(Saved, signing(Opts, ?STATE_COOKIE_AGE)), Opts
                ),
                livery_resp:redirect(302, Url, [Cookie]);
            {error, Status} ->
                livery_resp:text(Status, <<"could not start sign-in">>)
        end
    end.

%% RFC 9470 section 4: a client told to step up signs in again with the
%% `acr_values' and `max_age' it was given. Query values are taken only
%% when allowed, so a crafted link cannot pick the level.
requested(Req, Opts) ->
    AcrValues =
        case requested_acr(livery_ext:query(<<"acr_values">>, Req), Opts) of
            [] -> maps:get(acr_values, Opts, []);
            Acr -> Acr
        end,
    MaxAge = requested_max_age(livery_ext:query(<<"max_age">>, Req), Opts),
    maps:from_list(
        [{<<"acr_values">>, AcrValues} || AcrValues =/= []] ++
            [{<<"max_age">>, MaxAge} || is_integer(MaxAge)]
    ).

requested_acr(Q, Opts) when is_binary(Q) ->
    Allowed = maps:get(step_up_acr_values, Opts, []),
    Values = binary:split(Q, <<" ">>, [global, trim_all]),
    case lists:all(fun(V) -> lists:member(V, Allowed) end, Values) of
        true -> Values;
        false -> []
    end;
requested_acr(_Q, _Opts) ->
    [].

requested_max_age(Q, Opts) when is_binary(Q) ->
    case string:to_integer(Q) of
        {N, <<>>} when N >= 0 -> N;
        _ -> maps:get(max_age, Opts, undefined)
    end;
requested_max_age(_Q, Opts) ->
    maps:get(max_age, Opts, undefined).

authorization_params(State, Nonce, Verifier, StepUp, Opts) ->
    [
        {<<"response_type">>, <<"code">>},
        {<<"client_id">>, maps:get(client_id, Opts)},
        {<<"redirect_uri">>, maps:get(redirect_uri, Opts)},
        {<<"scope">>, iolist_to_binary(lists:join(<<" ">>, scopes(Opts)))},
        {<<"state">>, State},
        {<<"nonce">>, Nonce},
        {<<"code_challenge">>, b64(crypto:hash(sha256, Verifier))},
        {<<"code_challenge_method">>, <<"S256">>}
    ] ++ livery_auth_stepup:required(step_up_opts(StepUp)) ++ maps:get(params, Opts, []).

%% RFC 9126: with a PAR endpoint the request goes to the provider first
%% and the browser only carries `client_id' and the `request_uri'.
authorization_url(Params, Opts) ->
    Provider = maps:get(provider, Opts),
    #{<<"authorization_endpoint">> := Endpoint} = Provider,
    Required = maps:get(<<"require_pushed_authorization_requests">>, Provider, false),
    case par_mode(maps:get(par, Opts, auto), Required, Provider) of
        {push, Url} -> push(Url, Endpoint, Params, Opts);
        direct -> {ok, with_query(Endpoint, Params)};
        unavailable -> {error, 500}
    end.

%% A provider that requires PAR always gets it; `false' otherwise keeps
%% the classic redirect, `auto' pushes whenever the endpoint exists.
par_mode(Mode, Required, Provider) ->
    case
        {maps:get(<<"pushed_authorization_request_endpoint">>, Provider, undefined), Mode, Required}
    of
        {Url, _, true} when is_binary(Url) -> {push, Url};
        {undefined, _, true} -> unavailable;
        {undefined, true, _} -> unavailable;
        {undefined, _, _} -> direct;
        {_Url, false, _} -> direct;
        {Url, _, _} -> {push, Url}
    end.

push(ParEndpoint, Endpoint, Params, Opts) ->
    case livery_auth_token:push_request(ParEndpoint, Params, token_opts(Opts)) of
        {ok, #{request_uri := Uri}} ->
            {ok,
                with_query(Endpoint, [
                    {<<"client_id">>, maps:get(client_id, Opts)}, {<<"request_uri">>, Uri}
                ])};
        {error, _} ->
            {error, 502}
    end.

step_up_opts(StepUp) ->
    maps:from_list(
        [{acr_values, V} || {<<"acr_values">>, V} <- maps:to_list(StepUp)] ++
            [{max_age, V} || {<<"max_age">>, V} <- maps:to_list(StepUp)]
    ).

with_query(Url, Params) ->
    Sep =
        case binary:match(Url, <<"?">>) of
            nomatch -> <<"?">>;
            _ -> <<"&">>
        end,
    iolist_to_binary([Url, Sep, uri_string:compose_query(Params)]).

scopes(Opts) ->
    Scopes = maps:get(scope, Opts, [<<"openid">>]),
    [<<"openid">> | [S || S <- Scopes, S =/= <<"openid">>]].

%% Only a local path: `/x', but not `//host' or `/\host', which browsers
%% read as another site.
return_to(<<"/", C, _/binary>> = Path) when C =/= $/, C =/= $\\ -> Path;
return_to(<<"/">>) -> <<"/">>;
return_to(_) -> <<"/">>.

%%====================================================================
%% Callback
%%====================================================================

-doc "The handler the provider redirects the browser back to.".
-spec callback(map()) -> livery_middleware:handler().
callback(Opts) ->
    fun(Req) ->
        case saved_state(Req, Opts) of
            {ok, Saved} -> finish(Req, Saved, Opts);
            error -> refuse(400, <<"sign-in expired, please start again">>, Opts)
        end
    end.

saved_state(Req, Opts) ->
    case livery_ext:cookie(state_cookie_name(Opts), Req) of
        undefined ->
            error;
        Value ->
            case livery_auth_session:verify(Value, signing(Opts, ?STATE_COOKIE_AGE)) of
                {ok, Saved} -> {ok, Saved};
                {error, _} -> error
            end
    end.

finish(Req, Saved, Opts) ->
    Query = fun(Name) -> livery_ext:query(Name, Req) end,
    Steps = [
        fun() -> check_state(Query(<<"state">>), maps:get(<<"state">>, Saved)) end,
        fun() -> check_error(Query(<<"error">>)) end,
        fun() -> check_iss(Query(<<"iss">>), maps:get(provider, Opts)) end
    ],
    case run(Steps) of
        ok ->
            case exchange(Query(<<"code">>), Saved, Opts) of
                {ok, Claims, Token} -> signed_in(Claims, Token, Saved, Opts);
                {error, Detail} -> refuse(401, Detail, Opts)
            end;
        {error, Status, Detail} ->
            refuse(Status, Detail, Opts)
    end.

run([]) ->
    ok;
run([Step | Rest]) ->
    case Step() of
        ok -> run(Rest);
        Error -> Error
    end.

check_state(Got, Expected) when is_binary(Got), byte_size(Got) =:= byte_size(Expected) ->
    case crypto:hash_equals(Got, Expected) of
        true -> ok;
        false -> {error, 400, <<"sign-in state does not match">>}
    end;
check_state(_, _) ->
    {error, 400, <<"sign-in state does not match">>}.

check_error(undefined) -> ok;
check_error(Code) -> {error, 401, <<"sign-in refused by the provider: ", Code/binary>>}.

%% RFC 9207 2.4: compare `iss' when sent, and require it when the
%% provider advertises that it always sends it.
check_iss(undefined, #{<<"authorization_response_iss_parameter_supported">> := true}) ->
    {error, 400, <<"sign-in response has no issuer">>};
check_iss(undefined, _Provider) ->
    ok;
check_iss(Iss, #{<<"issuer">> := Iss}) ->
    ok;
check_iss(_Iss, _Provider) ->
    {error, 400, <<"sign-in response comes from another issuer">>}.

exchange(Code, Saved, Opts) when is_binary(Code) ->
    TokenOpts = token_opts(Opts),
    Params = #{
        code => Code,
        redirect_uri => maps:get(redirect_uri, Opts),
        code_verifier => maps:get(<<"verifier">>, Saved)
    },
    case livery_auth_token:request(authorization_code, Params, TokenOpts) of
        {ok, #{id_token := IdToken} = Token} -> id_token(IdToken, Token, Saved, Opts);
        {ok, _} -> {error, <<"provider sent no ID token">>};
        {error, _} -> {error, <<"could not redeem the sign-in code">>}
    end;
exchange(_Code, _Saved, _Opts) ->
    {error, <<"sign-in response has no code">>}.

%%====================================================================
%% ID token (OpenID Connect Core 1.0 3.1.3.7)
%%====================================================================

id_token(IdToken, Token, Saved, Opts) ->
    Provider = maps:get(provider, Opts),
    ClientId = maps:get(client_id, Opts),
    case keys(Provider, Opts) of
        {ok, Keys} ->
            VerifyOpts = maps:merge(maps:with([now, leeway], Opts), #{
                keys => Keys,
                issuer => maps:get(<<"issuer">>, Provider),
                audience => ClientId,
                algorithms => algorithms(Provider),
                required_claims => [<<"iss">>, <<"sub">>, <<"aud">>, <<"exp">>, <<"iat">>]
            }),
            case livery_auth:verify(IdToken, VerifyOpts) of
                {ok, Claims} -> oidc_checks(Claims, IdToken, Token, Saved, ClientId, Opts);
                {error, _} -> {error, <<"invalid ID token">>}
            end;
        {error, _} ->
            {error, <<"could not get the provider's keys">>}
    end.

token_opts(Opts) ->
    Provider = maps:get(provider, Opts),
    (maps:with(
        [client_id, client_auth, client_secret, private_key, key_id, adapter, adapter_opts, now],
        Opts
    ))#{
        token_endpoint => maps:get(<<"token_endpoint">>, Provider),
        issuer => maps:get(<<"issuer">>, Provider)
    }.

oidc_checks(Claims, IdToken, Token, Saved, ClientId, Opts) ->
    Nonce = maps:get(<<"nonce">>, Saved),
    Aud = maps:get(<<"aud">>, Claims),
    Azp = maps:get(<<"azp">>, Claims, undefined),
    Checks = [
        {maps:get(<<"nonce">>, Claims, undefined) =:= Nonce, <<"ID token nonce does not match">>},
        {azp_ok(Aud, Azp, ClientId), <<"ID token is for another client">>},
        {
            at_hash_ok(IdToken, maps:get(<<"at_hash">>, Claims, undefined), Token),
            <<"ID token at_hash does not match">>
        }
    ],
    case [Why || {false, Why} <- Checks] of
        [] -> step_up(Claims, Token, Saved, Opts);
        [Why | _] -> {error, Why}
    end.

%% OIDC Core 3.1.3.7 step 11 and RFC 9470 section 4: the sign-in must
%% meet the level and age that were asked for.
step_up(Claims, Token, Saved, Opts) ->
    Checks = maps:merge(maps:with([now, leeway], Opts), step_up_opts(Saved)),
    case livery_auth_stepup:check(Claims, Checks) of
        ok -> {ok, Claims, Token};
        {error, {insufficient_user_authentication, Why}} -> {error, Why}
    end.

%% Steps 4 and 5: with several audiences `azp' must name this client, and
%% when present it must always do so.
azp_ok(_Aud, ClientId, ClientId) -> true;
azp_ok(Aud, undefined, _ClientId) when is_binary(Aud) -> true;
azp_ok([_], undefined, _ClientId) -> true;
azp_ok(_Aud, _Azp, _ClientId) -> false.

%% 3.1.3.8 and 3.2.2.9: the left half of the access token's hash, with
%% the hash of the ID token's algorithm.
at_hash_ok(_IdToken, undefined, _Token) ->
    true;
at_hash_ok(IdToken, AtHash, #{access_token := Access}) ->
    case at_hash_alg(IdToken) of
        skip ->
            true;
        Hash ->
            Digest = crypto:hash(Hash, Access),
            b64(binary:part(Digest, 0, byte_size(Digest) div 2)) =:= AtHash
    end.

at_hash_alg(IdToken) ->
    [H | _] = binary:split(IdToken, <<".">>),
    {ok, #{<<"alg">> := Alg}} = livery_auth_jose:decode_json(H),
    case Alg of
        <<_:2/binary, "256">> -> sha256;
        <<_:2/binary, "384">> -> sha384;
        <<_:2/binary, "512">> -> sha512;
        <<"Ed25519">> -> sha512;
        <<"EdDSA">> -> sha512;
        _ -> skip
    end.

keys(_Provider, #{keys := Keys}) ->
    {ok, Keys};
keys(#{<<"jwks_uri">> := Uri}, Opts) ->
    livery_auth_jwks:keys(Uri, maps:with([fetch, ttl], Opts));
keys(_Provider, _Opts) ->
    {error, no_jwks_uri}.

algorithms(#{<<"id_token_signing_alg_values_supported">> := Advertised}) when is_list(Advertised) ->
    [A || A <- livery_auth_jose:algorithms(), lists:member(A, Advertised)];
algorithms(_Provider) ->
    livery_auth_jose:algorithms().

%%====================================================================
%% Session
%%====================================================================

signed_in(Claims, Token, Saved, Opts) ->
    OnLogin = maps:get(on_login, Opts, fun default_session/2),
    Session = maps:get(session, Opts),
    Data =
        case maps:get(keep_id_token, Opts, false) of
            true -> (OnLogin(Claims, Token))#{<<"id_token">> => maps:get(id_token, Token)};
            false -> OnLogin(Claims, Token)
        end,
    Value = livery_auth_session:sign(Data, Session),
    livery_resp:redirect(302, maps:get(<<"return_to">>, Saved), [
        livery_auth_session:set_cookie_header(Value, Session),
        clear_state_cookie(Opts)
    ]).

default_session(Claims, _Token) ->
    maps:with([<<"sub">>, <<"iss">>, <<"name">>, <<"email">>, <<"acr">>, <<"auth_time">>], Claims).

-doc """
The handler that ends the session: here, and at the provider when it
publishes an `end_session_endpoint`.
""".
-spec logout(map()) -> livery_middleware:handler().
logout(Opts) ->
    fun(Req) ->
        Session = maps:get(session, Opts),
        Clear = livery_auth_session:clear_cookie_header(Session),
        livery_resp:redirect(302, logout_target(Req, Opts), [Clear])
    end.

logout_target(Req, Opts) ->
    Provider = maps:get(provider, Opts),
    case
        {
            maps:get(provider_logout, Opts, true),
            maps:get(<<"end_session_endpoint">>, Provider, undefined)
        }
    of
        {true, Endpoint} when is_binary(Endpoint) ->
            Params =
                [{<<"client_id">>, maps:get(client_id, Opts)}] ++
                    [
                        {<<"post_logout_redirect_uri">>, U}
                     || U <- [maps:get(post_logout_redirect_uri, Opts, undefined)], U =/= undefined
                    ] ++
                    [
                        {<<"id_token_hint">>, T}
                     || T <- [session_id_token(Req, Opts)], T =/= undefined
                    ],
            with_query(Endpoint, Params);
        _ ->
            maps:get(after_logout, Opts, <<"/">>)
    end.

session_id_token(Req, Opts) ->
    Session = maps:get(session, Opts),
    case livery_ext:cookie(maps:get(name, Session, <<"session">>), Req) of
        undefined ->
            undefined;
        Value ->
            case livery_auth_session:verify(Value, Session) of
                {ok, #{<<"id_token">> := IdToken}} when is_binary(IdToken) -> IdToken;
                _ -> undefined
            end
    end.

refuse(Status, Detail, Opts) ->
    livery_resp:with_header(
        element(1, clear_state_cookie(Opts)),
        element(2, clear_state_cookie(Opts)),
        livery_resp:text(Status, Detail)
    ).

%%====================================================================
%% State cookie
%%====================================================================

state_cookie(Value, Opts) ->
    livery_auth_session:set_cookie_header(Value, state_cookie_opts(Opts)).

clear_state_cookie(Opts) ->
    livery_auth_session:clear_cookie_header(state_cookie_opts(Opts)).

%% Scoped to the callback, readable only there, gone after ten minutes.
%% `Lax' lets it come back on the provider's top-level redirect.
state_cookie_opts(Opts) ->
    #{
        name => state_cookie_name(Opts),
        path => callback_path(Opts),
        max_age => ?STATE_COOKIE_AGE,
        same_site => <<"Lax">>,
        secure => maps:get(secure, maps:get(session, Opts), true),
        http_only => true
    }.

state_cookie_name(Opts) ->
    <<(maps:get(name, maps:get(session, Opts), <<"session">>))/binary, "_login">>.

signing(Opts, MaxAge) ->
    #{secret => maps:get(secret, maps:get(session, Opts)), max_age => MaxAge}.

callback_path(Opts) ->
    #{path := Path} = uri_string:parse(maps:get(redirect_uri, Opts)),
    Path.

logout_path(Opts) ->
    maps:get(logout_path, Opts, <<"/logout">>).

random() ->
    b64(crypto:strong_rand_bytes(32)).

b64(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).
