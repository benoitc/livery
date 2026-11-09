-module(livery_auth).
-moduledoc """
JWT verification against a JWK set.

Verifies compact-serialization JSON Web Tokens signed with any of the
asymmetric algorithms in `livery_auth_jose` (RSA, RSA-PSS, ECDSA and
EdDSA), then validates the registered claims. Signature checks use the
OTP `public_key` and `crypto` modules; no third-party crypto is pulled
in. The JWK set is supplied by the caller (see `livery_auth_jwks` to
fetch one), so verification itself never touches the network.

```erlang
{ok, Claims} = livery_auth:verify(Token, #{
    keys     => JwkList,
    issuer   => <<"https://issuer.example">>,
    audience => <<"my-api">>
}).
```

Options:

- `keys` (required): the JWK maps to verify against.
- `issuer`, `audience`: expected `iss`, and one or a list of accepted
  `aud` values.
- `algorithms`: accepted `alg` values, default
  `livery_auth_jose:algorithms/0`.
- `typ`: required header `typ`, one value or a list, compared without
  case and with the `application/` prefix optional (RFC 7515 4.1.9).
- `required_claims`: claim names that must be present.
- `scope`: scopes the token must grant, read from `scope` (space
  separated) or `scp` (a list).
- `profile => access_token`: the RFC 9068 profile. Requires `typ`
  `at+jwt`, the claims `iss`, `exp`, `aud`, `sub`, `client_id`, `iat`
  and `jti`, and the `issuer` and `audience` options.
- `now`, `leeway`: clock and allowed skew, in seconds.

A token with a `crit` header is refused, since no JWS extension is
understood (RFC 7515 4.1.11). `exp`, `nbf` and `iat` may be any JSON
number (RFC 7519 2).

Deviations: `typ` is not required unless asked for, although RFC 8725
3.11 recommends explicit typing, because most issuers send `JWT` or
nothing. `scp` is read as well as `scope`, because Azure AD and Okta
issue it. See AGENTS.md, Known deviations.
""".

-export([verify/2, tls_opts/0, missing_scopes/2, audience_matches/2]).

-export_type([jwk/0, verify_opts/0, claims/0, error_reason/0]).

-type jwk() :: #{binary() => term()}.
-type claims() :: #{binary() => term()}.

-type verify_opts() :: #{
    keys := [jwk()],
    issuer => binary() | undefined,
    audience => binary() | [binary()] | undefined,
    algorithms => [binary()],
    typ => binary() | [binary()],
    required_claims => [binary()],
    scope => [binary()],
    profile => access_token,
    now => number(),
    leeway => non_neg_integer()
}.

-type error_reason() ::
    malformed
    | invalid_json
    | {unsupported_alg, term()}
    | {unsupported_crit, term()}
    | {invalid_typ, term()}
    | no_matching_key
    | bad_signature
    | expired
    | not_yet_valid
    | {invalid_claim, binary()}
    | {missing_claim, binary()}
    | {missing_option, issuer | audience}
    | {issuer_mismatch, binary()}
    | audience_mismatch
    | {insufficient_scope, [binary()]}.

-define(AT_CLAIMS, [
    <<"iss">>, <<"exp">>, <<"aud">>, <<"sub">>, <<"client_id">>, <<"iat">>, <<"jti">>
]).

%%====================================================================
%% Public API
%%====================================================================

-doc """
Verify a JWT and return its validated claims.

Steps: split the compact token, check the header (`crit`, `typ`, `alg`),
find a fitting key and verify the signature, then validate the claims.
""".
-spec verify(binary(), verify_opts()) ->
    {ok, claims()} | {error, error_reason()}.
verify(Token, Opts0) when is_binary(Token) ->
    case profile(Opts0) of
        {ok, Opts} ->
            case binary:split(Token, <<".">>, [global]) of
                [H, P, S] -> with_decoded(H, P, S, <<H/binary, ".", P/binary>>, Opts);
                _ -> {error, malformed}
            end;
        {error, _} = E ->
            E
    end.

-doc """
Scopes from `Required` that `Claims` does not grant, read from `scope`
(space separated, RFC 9068 2.2.3 and RFC 7662 2.2) or `scp` (a list).
""".
-spec missing_scopes(map(), [binary()]) -> [binary()].
missing_scopes(Claims, Required) ->
    Granted = granted_scopes(Claims),
    [S || S <- Required, not lists:member(S, Granted)].

-doc """
Whether an `aud` value (a string or a list) contains one of `Expected`
(one value or a list).
""".
-spec audience_matches(term(), binary() | [binary()]) -> boolean().
audience_matches(Aud, Expected) when is_binary(Aud) ->
    audience_matches([Aud], Expected);
audience_matches(AudList, Expected) when is_list(AudList), is_binary(Expected) ->
    lists:member(Expected, AudList);
audience_matches(AudList, ExpectedList) when is_list(AudList), is_list(ExpectedList) ->
    lists:any(fun(E) -> lists:member(E, AudList) end, ExpectedList);
audience_matches(_, _) ->
    false.

-doc """
TLS client options for verifying an HTTPS peer's certificate.

Used by the OIDC/JWKS/introspection fetchers so the channel that
discovers signing keys (and thus the identity trust root) is
authenticated: a forged JWK set served by an on-path attacker would
otherwise let them mint tokens this node accepts. Verifies against
the OS trust store with hostname checking.
""".
-spec tls_opts() -> [ssl:tls_client_option()].
tls_opts() ->
    [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]},
        {depth, 99}
    ].

%%====================================================================
%% Options
%%====================================================================

%% RFC 9068 4: the resource server MUST check `iss' and `aud', so the
%% profile refuses to run without them rather than skip the checks.
profile(#{profile := access_token} = Opts) ->
    case {maps:get(issuer, Opts, undefined), maps:get(audience, Opts, undefined)} of
        {undefined, _} ->
            {error, {missing_option, issuer}};
        {_, undefined} ->
            {error, {missing_option, audience}};
        _ ->
            Required = maps:get(required_claims, Opts, []),
            {ok, Opts#{
                typ => maps:get(typ, Opts, <<"at+jwt">>),
                required_claims => lists:usort(Required ++ ?AT_CLAIMS)
            }}
    end;
profile(Opts) ->
    {ok, Opts}.

%%====================================================================
%% Header
%%====================================================================

with_decoded(HeaderB64, PayloadB64, SigB64, SigningInput, Opts) ->
    case {decode_json(HeaderB64), decode_json(PayloadB64), livery_auth_jose:b64url(SigB64)} of
        {{ok, Header}, {ok, Claims}, {ok, Sig}} ->
            verify_decoded(Header, Claims, Sig, SigningInput, Opts);
        _ ->
            {error, invalid_json}
    end.

verify_decoded(Header, Claims, Sig, SigningInput, Opts) ->
    case check_header(Header, Opts) of
        ok ->
            case
                livery_auth_jose:verify(
                    maps:get(<<"alg">>, Header, undefined),
                    maps:get(<<"kid">>, Header, undefined),
                    SigningInput,
                    Sig,
                    maps:get(keys, Opts, []),
                    maps:get(algorithms, Opts, livery_auth_jose:algorithms())
                )
            of
                ok -> validate_claims(Claims, Opts);
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

check_header(#{<<"crit">> := Crit}, _Opts) ->
    {error, {unsupported_crit, Crit}};
check_header(Header, #{typ := Expected}) ->
    Typ = maps:get(<<"typ">>, Header, undefined),
    case typ_matches(Typ, Expected) of
        true -> ok;
        false -> {error, {invalid_typ, Typ}}
    end;
check_header(_Header, _Opts) ->
    ok.

typ_matches(Typ, Expected) when is_binary(Typ), is_binary(Expected) ->
    media_type(Typ) =:= media_type(Expected);
typ_matches(Typ, Expected) when is_binary(Typ), is_list(Expected) ->
    lists:any(fun(E) -> typ_matches(Typ, E) end, Expected);
typ_matches(_, _) ->
    false.

media_type(T) ->
    case string:lowercase(T) of
        <<"application/", Rest/binary>> -> Rest;
        Lower -> Lower
    end.

%%====================================================================
%% Claims
%%====================================================================

validate_claims(Claims, Opts) ->
    Now = maps:get(now, Opts, os:system_time(second)),
    Leeway = maps:get(leeway, Opts, 0),
    Checks = [
        fun() -> check_required(Claims, maps:get(required_claims, Opts, [])) end,
        fun() -> check_numeric(Claims, [<<"exp">>, <<"nbf">>, <<"iat">>]) end,
        fun() -> check_exp(Claims, Now, Leeway) end,
        fun() -> check_nbf(Claims, Now, Leeway) end,
        fun() -> check_iss(Claims, maps:get(issuer, Opts, undefined)) end,
        fun() -> check_aud(Claims, maps:get(audience, Opts, undefined)) end,
        fun() -> check_scope(Claims, maps:get(scope, Opts, [])) end
    ],
    run_checks(Checks, Claims).

run_checks([], Claims) ->
    {ok, Claims};
run_checks([Check | Rest], Claims) ->
    case Check() of
        ok -> run_checks(Rest, Claims);
        {error, _} = E -> E
    end.

check_required(_Claims, []) ->
    ok;
check_required(Claims, [Name | Rest]) ->
    case maps:is_key(Name, Claims) of
        true -> check_required(Claims, Rest);
        false -> {error, {missing_claim, Name}}
    end.

check_numeric(_Claims, []) ->
    ok;
check_numeric(Claims, [Name | Rest]) ->
    case maps:get(Name, Claims, undefined) of
        undefined -> check_numeric(Claims, Rest);
        V when is_number(V) -> check_numeric(Claims, Rest);
        _ -> {error, {invalid_claim, Name}}
    end.

check_exp(Claims, Now, Leeway) ->
    case maps:get(<<"exp">>, Claims, undefined) of
        undefined -> ok;
        Exp when Now =< Exp + Leeway -> ok;
        _ -> {error, expired}
    end.

check_nbf(Claims, Now, Leeway) ->
    case maps:get(<<"nbf">>, Claims, undefined) of
        undefined -> ok;
        Nbf when Now + Leeway >= Nbf -> ok;
        _ -> {error, not_yet_valid}
    end.

check_iss(_Claims, undefined) ->
    ok;
check_iss(Claims, Expected) ->
    case maps:get(<<"iss">>, Claims, undefined) of
        Expected -> ok;
        _ -> {error, {issuer_mismatch, Expected}}
    end.

check_aud(_Claims, undefined) ->
    ok;
check_aud(Claims, Expected) ->
    case audience_matches(maps:get(<<"aud">>, Claims, undefined), Expected) of
        true -> ok;
        false -> {error, audience_mismatch}
    end.

check_scope(_Claims, []) ->
    ok;
check_scope(Claims, Required) ->
    case missing_scopes(Claims, Required) of
        [] -> ok;
        Missing -> {error, {insufficient_scope, Missing}}
    end.

granted_scopes(Claims) ->
    scopes(maps:get(<<"scope">>, Claims, undefined)) ++
        scopes(maps:get(<<"scp">>, Claims, undefined)).

scopes(S) when is_binary(S) -> binary:split(S, <<" ">>, [global, trim_all]);
scopes(L) when is_list(L) -> [V || V <- L, is_binary(V)];
scopes(_) -> [].

%%====================================================================
%% base64url + JSON
%%====================================================================

-spec decode_json(binary()) -> {ok, map()} | error.
decode_json(B64) ->
    case livery_auth_jose:b64url(B64) of
        {ok, Bin} ->
            %% A JOSE header and a claims set are both JSON objects.
            try json:decode(Bin) of
                #{} = Map -> {ok, Map};
                _ -> error
            catch
                _:_ -> error
            end;
        error ->
            error
    end.
