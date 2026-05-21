-module(livery_auth).
-moduledoc """
JWT verification against a JWK set.

Verifies compact-serialization JSON Web Tokens signed with RS256
or ES256, then validates the registered claims (`exp`, `nbf`,
`iss`, `aud`). Signature verification and key handling use the OTP
`public_key` and `crypto` modules; no third-party crypto is
pulled in.

The JWK set is supplied by the caller. OIDC discovery and live
JWKS rotation over HTTP are a thin layer that can sit on top of
this module (a follow-up); keeping verification network-free makes
it cheap to test and embed.

```erlang
{ok, Claims} = livery_auth:verify(Token, #{
    keys     => JwkList,
    issuer   => <<"https://issuer.example">>,
    audience => <<"my-api">>
}).
```

A JWK is a map with binary keys, e.g. for RSA:
`#{<<"kty">> => <<"RSA">>, <<"kid">> => _, <<"n">> => _, <<"e">> => _}`
and for EC P-256:
`#{<<"kty">> => <<"EC">>, <<"crv">> => <<"P-256">>, <<"x">> => _, <<"y">> => _}`.
""".

-include_lib("public_key/include/public_key.hrl").

-export([verify/2]).

-export_type([jwk/0, verify_opts/0, claims/0, error_reason/0]).

-type jwk() :: #{binary() => binary()}.
-type claims() :: #{binary() => term()}.

-type verify_opts() :: #{
    keys := [jwk()],
    issuer => binary() | undefined,
    audience => binary() | [binary()] | undefined,
    now => non_neg_integer(),
    leeway => non_neg_integer()
}.

-type error_reason() ::
    malformed
    | invalid_json
    | {unsupported_alg, binary()}
    | no_matching_key
    | bad_signature
    | expired
    | not_yet_valid
    | {issuer_mismatch, binary()}
    | audience_mismatch.

%%====================================================================
%% Public API
%%====================================================================

-doc """
Verify a JWT and return its validated claims.

Steps: split the compact token, decode the header to pick the
algorithm and key id, find the matching JWK, verify the
signature, then validate `exp`/`nbf`/`iss`/`aud`.
""".
-spec verify(binary(), verify_opts()) ->
    {ok, claims()} | {error, error_reason()}.
verify(Token, Opts) when is_binary(Token) ->
    case split(Token) of
        {ok, HeaderB64, PayloadB64, SigB64, SigningInput} ->
            with_decoded(HeaderB64, PayloadB64, SigB64, SigningInput, Opts);
        error ->
            {error, malformed}
    end.

%%====================================================================
%% Internals
%%====================================================================

-spec split(binary()) ->
    {ok, binary(), binary(), binary(), binary()} | error.
split(Token) ->
    case binary:split(Token, <<".">>, [global]) of
        [H, P, S] ->
            {ok, H, P, S, <<H/binary, ".", P/binary>>};
        _ ->
            error
    end.

with_decoded(HeaderB64, PayloadB64, SigB64, SigningInput, Opts) ->
    case {decode_json(HeaderB64), decode_json(PayloadB64), b64url(SigB64)} of
        {{ok, Header}, {ok, Claims}, {ok, Sig}} ->
            verify_decoded(Header, Claims, Sig, SigningInput, Opts);
        _ ->
            {error, invalid_json}
    end.

verify_decoded(Header, Claims, Sig, SigningInput, Opts) ->
    Alg = maps:get(<<"alg">>, Header, undefined),
    Kid = maps:get(<<"kid">>, Header, undefined),
    case find_key(Alg, Kid, maps:get(keys, Opts, [])) of
        {ok, Jwk} ->
            case verify_signature(Alg, SigningInput, Sig, Jwk) of
                true -> validate_claims(Claims, Opts);
                false -> {error, bad_signature}
            end;
        {error, unsupported} ->
            {error, {unsupported_alg, Alg}};
        {error, not_found} ->
            {error, no_matching_key}
    end.

%%====================================================================
%% Key selection
%%====================================================================

find_key(Alg, _Kid, _Keys) when Alg =/= <<"RS256">>, Alg =/= <<"ES256">> ->
    {error, unsupported};
find_key(_Alg, Kid, Keys) ->
    Matching = [K || K <- Keys, key_matches(K, Kid)],
    case Matching of
        [K | _] -> {ok, K};
        [] -> {error, not_found}
    end.

%% When the token carries a kid, require it to match; otherwise fall
%% back to any key (single-key deployments routinely omit kid).
key_matches(_Jwk, undefined) -> true;
key_matches(Jwk, Kid) -> maps:get(<<"kid">>, Jwk, undefined) =:= Kid.

%%====================================================================
%% Signature verification
%%====================================================================

verify_signature(<<"RS256">>, SigningInput, Sig, Jwk) ->
    case rsa_public_key(Jwk) of
        {ok, PubKey} ->
            public_key:verify(SigningInput, sha256, Sig, PubKey);
        error ->
            false
    end;
verify_signature(<<"ES256">>, SigningInput, Sig, Jwk) ->
    case ec_public_key(Jwk) of
        {ok, PubKey} ->
            case raw_to_der_sig(Sig) of
                {ok, DerSig} ->
                    public_key:verify(SigningInput, sha256, DerSig, PubKey);
                error ->
                    false
            end;
        error ->
            false
    end.

-spec rsa_public_key(jwk()) -> {ok, #'RSAPublicKey'{}} | error.
rsa_public_key(#{<<"n">> := N64, <<"e">> := E64}) ->
    case {b64url(N64), b64url(E64)} of
        {{ok, N}, {ok, E}} ->
            {ok, #'RSAPublicKey'{
                modulus = binary:decode_unsigned(N),
                publicExponent = binary:decode_unsigned(E)
            }};
        _ ->
            error
    end;
rsa_public_key(_) ->
    error.

-spec ec_public_key(jwk()) -> {ok, term()} | error.
ec_public_key(#{<<"x">> := X64, <<"y">> := Y64}) ->
    case {b64url(X64), b64url(Y64)} of
        {{ok, X}, {ok, Y}} when byte_size(X) =:= 32, byte_size(Y) =:= 32 ->
            Point = #'ECPoint'{point = <<4, X/binary, Y/binary>>},
            Params = {namedCurve, ?'secp256r1'},
            {ok, {Point, Params}};
        _ ->
            error
    end;
ec_public_key(_) ->
    error.

%% JWS ECDSA signatures are the raw r||s concatenation (RFC 7518
%% §3.4). OTP's public_key:verify wants a DER-encoded
%% ECDSA-Sig-Value.
-spec raw_to_der_sig(binary()) -> {ok, binary()} | error.
raw_to_der_sig(<<R:32/binary, S:32/binary>>) ->
    RInt = binary:decode_unsigned(R),
    SInt = binary:decode_unsigned(S),
    {ok,
        public_key:der_encode(
            'ECDSA-Sig-Value',
            #'ECDSA-Sig-Value'{r = RInt, s = SInt}
        )};
raw_to_der_sig(_) ->
    error.

%%====================================================================
%% Claim validation
%%====================================================================

validate_claims(Claims, Opts) ->
    Now = maps:get(now, Opts, os:system_time(second)),
    Leeway = maps:get(leeway, Opts, 0),
    Checks = [
        fun() -> check_exp(Claims, Now, Leeway) end,
        fun() -> check_nbf(Claims, Now, Leeway) end,
        fun() -> check_iss(Claims, maps:get(issuer, Opts, undefined)) end,
        fun() -> check_aud(Claims, maps:get(audience, Opts, undefined)) end
    ],
    run_checks(Checks, Claims).

run_checks([], Claims) ->
    {ok, Claims};
run_checks([Check | Rest], Claims) ->
    case Check() of
        ok -> run_checks(Rest, Claims);
        {error, _} = E -> E
    end.

check_exp(Claims, Now, Leeway) ->
    case maps:get(<<"exp">>, Claims, undefined) of
        undefined -> ok;
        Exp when is_integer(Exp), Now =< Exp + Leeway -> ok;
        _ -> {error, expired}
    end.

check_nbf(Claims, Now, Leeway) ->
    case maps:get(<<"nbf">>, Claims, undefined) of
        undefined -> ok;
        Nbf when is_integer(Nbf), Now + Leeway >= Nbf -> ok;
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
    Aud = maps:get(<<"aud">>, Claims, undefined),
    case audience_ok(Aud, Expected) of
        true -> ok;
        false -> {error, audience_mismatch}
    end.

%% `aud` may be a string or an array; `Expected` may be one value or
%% a list of acceptable values. Match if any expected value appears.
audience_ok(undefined, _Expected) ->
    false;
audience_ok(Aud, Expected) when is_binary(Aud) ->
    audience_ok([Aud], Expected);
audience_ok(AudList, Expected) when is_list(AudList), is_binary(Expected) ->
    lists:member(Expected, AudList);
audience_ok(AudList, ExpectedList) when is_list(AudList), is_list(ExpectedList) ->
    lists:any(fun(E) -> lists:member(E, AudList) end, ExpectedList);
audience_ok(_, _) ->
    false.

%%====================================================================
%% base64url + JSON
%%====================================================================

-spec decode_json(binary()) -> {ok, map()} | error.
decode_json(B64) ->
    case b64url(B64) of
        {ok, Bin} ->
            try
                {ok, json:decode(Bin)}
            catch
                _:_ -> error
            end;
        error ->
            error
    end.

-spec b64url(binary()) -> {ok, binary()} | error.
b64url(B64) ->
    try
        {ok, base64:decode(B64, #{mode => urlsafe, padding => false})}
    catch
        _:_ -> error
    end.
