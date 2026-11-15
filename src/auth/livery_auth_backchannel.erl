-module(livery_auth_backchannel).
-moduledoc """
OpenID Connect Back-Channel Logout 1.0: the route an identity provider
calls to say a user logged out, so this application ends their sessions
too.

You do not usually call this module yourself: set
`backchannel_logout_path` in the `livery_auth_login` options and
`livery_auth_login:routes/1` adds the route, with a body limit and a rate
limit. Register that URL with the provider as the client's
`backchannel_logout_uri`.

The provider POSTs a form with a `logout_token`, a JWT it signs. It is
checked as the specification says (sections 2.4 and 2.6): the signature
with the provider's keys, `iss`, `aud` holding the client id, `iat`,
`exp`, a `jti` not seen before, the back-channel logout event, a `sub` or
a `sid`, and no `nonce`. A token that fails any check is answered `400`.

The `typ` header is not checked unless you ask: the specification only
recommends that providers send `logout+jwt` and warns that requiring it
breaks most deployments (sections 2.4 and 4.1). Set
`backchannel_require_typ => true` to refuse logout tokens not typed
`logout+jwt`, when your provider sends it.

A valid token ends sessions in the `session` store (see
`livery_auth_session_store`): the one opened from the provider session
named by `sid`, or, with only `sub`, every session of that user at this
provider. Then `on_logout(Iss, Sub, Sid)` runs, if you gave one, with
`undefined` for a claim the token does not carry; use it to end what
else the user has open (a WebSocket, a call). The answer is `200`.

Options read from the login options: `provider`, `client_id`, `keys` or
`fetch`, `leeway`, `session` (its `store`), `on_logout`,
`backchannel_session_required` (refuse tokens without `sid`, default
`false`), `backchannel_require_typ` (default `false`),
`logout_token_max_age` (how old `iat` may be, default 300 seconds) and
`logout_replay` (a `fun((Key, ExpiresAt) -> fresh | replayed)` to share
seen token ids across a cluster; by default they are kept in
`livery_auth_dpop_store`, on this node).

Encrypted logout tokens are refused: Livery does not decrypt JWE.
""".

-export([handler/1, verify/2]).

-export_type([logout/0]).

-type logout() :: #{iss := binary(), sub := binary() | undefined, sid := binary() | undefined}.

-define(EVENT, <<"http://schemas.openid.net/event/backchannel-logout">>).
-define(MAX_BODY, 16384).
-define(MAX_AGE, 300).

-doc "The handler for the back-channel logout route (POST).".
-spec handler(map()) -> livery_middleware:handler().
handler(Opts) ->
    fun(Req) ->
        case logout_token(Req) of
            {ok, Token} ->
                case verify(Token, Opts) of
                    {ok, Logout} -> act(Logout, Opts);
                    {error, Reason} -> refused(describe(Reason))
                end;
            error ->
                refused(<<"the request has no logout_token">>)
        end
    end.

-doc """
Check a logout token (sections 2.4 and 2.6) and return who it logs out.
""".
-spec verify(binary(), map()) -> {ok, logout()} | {error, term()}.
verify(Token, Opts) ->
    maybe
        [H, _, _] ?= binary:split(Token, <<".">>, [global]),
        {ok, Header} ?= header(H),
        ok ?= check_typ(maps:get(<<"typ">>, Header, undefined), Opts),
        {ok, Keys} ?= keys(Opts),
        {ok, Claims} ?= livery_auth:verify(Token, verify_opts(Keys, Opts)),
        ok ?= check_iat(maps:get(<<"iat">>, Claims), Opts),
        ok ?= check_events(maps:get(<<"events">>, Claims)),
        ok ?= check_nonce(Claims),
        {ok, Logout} ?= subject(Claims, Opts),
        ok ?= once(Claims, Opts),
        {ok, Logout}
    else
        Parts when is_list(Parts) -> {error, malformed};
        {error, _} = E -> E
    end.

%%====================================================================
%% Request
%%====================================================================

logout_token(Req) ->
    case livery_ext:read_form(Req, #{max_size => ?MAX_BODY}) of
        {ok, Form} ->
            case lists:keyfind(<<"logout_token">>, 1, Form) of
                {_, Token} when byte_size(Token) > 0 -> {ok, Token};
                _ -> error
            end;
        {error, _} ->
            error
    end.

%% Section 2.7: end the sessions the token names, then let the
%% application act. Section 2.8: anything that fails is a 400.
act(#{iss := Iss, sub := Sub, sid := Sid}, Opts) ->
    try
        ok = revoke(store(Opts), Iss, Sub, Sid),
        case maps:get(on_logout, Opts, undefined) of
            undefined -> ok;
            OnLogout -> _ = OnLogout(Iss, Sub, Sid)
        end
    of
        _ -> livery_resp:with_header(<<"cache-control">>, <<"no-store">>, livery_resp:empty(200))
    catch
        _:_ -> refused(<<"the logout could not be completed">>)
    end.

revoke(undefined, _Iss, _Sub, _Sid) ->
    ok;
revoke(Store, Iss, _Sub, Sid) when is_binary(Sid) ->
    livery_auth_session_store:revoke_provider_session(Store, Iss, Sid);
revoke(Store, Iss, Sub, undefined) ->
    livery_auth_session_store:revoke_user(Store, Iss, Sub).

store(Opts) ->
    maps:get(store, maps:get(session, Opts, #{}), undefined).

refused(Description) ->
    Body = json:encode(#{
        <<"error">> => <<"invalid_request">>, <<"error_description">> => Description
    }),
    livery_resp:json(400, [{<<"cache-control">>, <<"no-store">>}], Body).

describe(malformed) -> <<"the logout token is malformed">>;
describe({invalid_typ, _}) -> <<"the logout token has the wrong type">>;
describe(expired) -> <<"the logout token has expired">>;
describe(too_old) -> <<"the logout token is too old">>;
describe(issued_in_future) -> <<"the logout token is issued in the future">>;
describe(no_logout_event) -> <<"the logout token has no back-channel logout event">>;
describe(nonce_present) -> <<"the logout token carries a nonce">>;
describe(no_subject) -> <<"the logout token names neither sub nor sid">>;
describe(sid_required) -> <<"the logout token has no sid">>;
describe(replayed) -> <<"the logout token was already used">>;
describe({missing_claim, _}) -> <<"the logout token lacks a required claim">>;
describe(no_keys) -> <<"the provider's keys are not available">>;
describe(_) -> <<"the logout token is not valid">>.

%%====================================================================
%% Logout token
%%====================================================================

header(H) ->
    case livery_auth_jose:decode_json(H) of
        {ok, Header} -> {ok, Header};
        error -> {error, malformed}
    end.

%% Sections 2.4 and 4.1: explicit typing is recommended, not required,
%% so `typ' is only checked when the application asks for it.
check_typ(Typ, #{backchannel_require_typ := true}) ->
    case is_binary(Typ) andalso string:lowercase(Typ) of
        <<"logout+jwt">> -> ok;
        <<"application/logout+jwt">> -> ok;
        _ -> {error, {invalid_typ, Typ}}
    end;
check_typ(_Typ, _Opts) ->
    ok.

keys(Opts) ->
    case livery_auth_login:keys(maps:get(provider, Opts), Opts) of
        {ok, Keys} -> {ok, Keys};
        {error, _} -> {error, no_keys}
    end.

verify_opts(Keys, Opts) ->
    Provider = maps:get(provider, Opts),
    maps:merge(maps:with([now, leeway], Opts), #{
        keys => Keys,
        issuer => maps:get(<<"issuer">>, Provider),
        audience => maps:get(client_id, Opts),
        algorithms => livery_auth_login:algorithms(Provider),
        required_claims => [
            <<"iss">>, <<"aud">>, <<"iat">>, <<"exp">>, <<"jti">>, <<"events">>
        ]
    }).

%% Section 2.6 step 4 checks `iat' as for an ID token, which OpenID
%% Connect Core 3.1.3.7 step 10 lets the client bound.
check_iat(Iat, Opts) ->
    Now = now(Opts),
    Leeway = maps:get(leeway, Opts, 0),
    MaxAge = maps:get(logout_token_max_age, Opts, ?MAX_AGE),
    case Iat of
        _ when Iat > Now + Leeway -> {error, issued_in_future};
        _ when Iat < Now - MaxAge - Leeway -> {error, too_old};
        _ -> ok
    end.

check_events(#{?EVENT := Event}) when is_map(Event) -> ok;
check_events(_) -> {error, no_logout_event}.

check_nonce(#{<<"nonce">> := _}) -> {error, nonce_present};
check_nonce(_) -> ok.

subject(#{<<"iss">> := Iss} = Claims, Opts) ->
    Sub = text(maps:get(<<"sub">>, Claims, undefined)),
    Sid = text(maps:get(<<"sid">>, Claims, undefined)),
    case {Sub, Sid, maps:get(backchannel_session_required, Opts, false)} of
        {undefined, undefined, _} -> {error, no_subject};
        {_, undefined, true} -> {error, sid_required};
        _ -> {ok, #{iss => Iss, sub => Sub, sid => Sid}}
    end.

text(V) when is_binary(V), byte_size(V) > 0 -> V;
text(_) -> undefined.

%% Section 2.6 step 8. A token is refused once `iat' is older than the
%% maximum age, so its id need not be kept past that or past `exp'.
once(#{<<"iss">> := Iss, <<"jti">> := Jti, <<"iat">> := Iat, <<"exp">> := Exp}, Opts) when
    is_binary(Jti)
->
    Leeway = maps:get(leeway, Opts, 0),
    MaxAge = maps:get(logout_token_max_age, Opts, ?MAX_AGE),
    Until = trunc(min(Exp, Iat + MaxAge)) + Leeway,
    Claim = maps:get(logout_replay, Opts, fun livery_auth_dpop_store:claim/2),
    case Claim(<<"backchannel-logout:", Iss/binary, 0, Jti/binary>>, Until) of
        fresh -> ok;
        replayed -> {error, replayed}
    end;
once(_Claims, _Opts) ->
    {error, malformed}.

now(Opts) ->
    maps:get(now, Opts, os:system_time(second)).
