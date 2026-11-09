-module(livery_auth_jose).
-moduledoc """
JWS signature checks for `livery_auth`.

Supports the asymmetric algorithms of RFC 7518 and RFC 9864: RS256,
RS384, RS512, PS256, PS384, PS512, ES256, ES384, ES512, Ed25519 and
Ed448, plus the older `EdDSA` name, whose curve comes from the key.
`none` and the HMAC algorithms are never accepted: a resource server
has no business sharing a signing secret with its issuer.

A key is used for a token only when everything it says about itself
agrees with the token: its `kty` and `crv` fit the algorithm, its `alg`
(if present) names it, its `use` (if present) is `sig`, its `key_ops`
(if present) include `verify`, and its `kid` matches when the token
carries one. RSA keys shorter than 2048 bits are skipped (RFC 7518
section 3.3). Without a `kid`, every fitting key is tried in order.

Deviations: `EdDSA` is still accepted although RFC 9864 deprecates it,
because most issuers still send it. See AGENTS.md, Known deviations.
""".

-include_lib("public_key/include/public_key.hrl").

-export([algorithms/0, verify/6, b64url/1]).

-type spec() ::
    {rsa, atom(), pkcs1 | pss}
    | {ec, atom(), binary(), pos_integer()}
    | {okp, binary() | any}.

-doc "Every algorithm Livery can verify, the default allow list.".
-spec algorithms() -> [binary()].
algorithms() ->
    [
        <<"RS256">>,
        <<"RS384">>,
        <<"RS512">>,
        <<"PS256">>,
        <<"PS384">>,
        <<"PS512">>,
        <<"ES256">>,
        <<"ES384">>,
        <<"ES512">>,
        <<"Ed25519">>,
        <<"Ed448">>,
        <<"EdDSA">>
    ].

-doc """
Check `Sig` over `SigningInput` with a key from `Keys` that fits `Alg`
and `Kid`, among the `Allowed` algorithms.
""".
-spec verify(term(), term(), binary(), binary(), [livery_auth:jwk()], [binary()]) ->
    ok | {error, {unsupported_alg, term()} | no_matching_key | bad_signature}.
verify(Alg, Kid, SigningInput, Sig, Keys, Allowed) ->
    case is_binary(Alg) andalso lists:member(Alg, Allowed) andalso spec(Alg) of
        false ->
            {error, {unsupported_alg, Alg}};
        Spec ->
            case [K || K <- Keys, is_map(K), usable(Alg, Spec, Kid, K)] of
                [] -> {error, no_matching_key};
                Candidates -> try_keys(Spec, SigningInput, Sig, Candidates)
            end
    end.

-doc "Decode unpadded base64url.".
-spec b64url(binary()) -> {ok, binary()} | error.
b64url(B64) ->
    try
        {ok, base64:decode(B64, #{mode => urlsafe, padding => false})}
    catch
        _:_ -> error
    end.

%%====================================================================
%% Algorithms
%%====================================================================

-spec spec(binary()) -> spec() | false.
spec(<<"RS256">>) -> {rsa, sha256, pkcs1};
spec(<<"RS384">>) -> {rsa, sha384, pkcs1};
spec(<<"RS512">>) -> {rsa, sha512, pkcs1};
spec(<<"PS256">>) -> {rsa, sha256, pss};
spec(<<"PS384">>) -> {rsa, sha384, pss};
spec(<<"PS512">>) -> {rsa, sha512, pss};
spec(<<"ES256">>) -> {ec, sha256, <<"P-256">>, 32};
spec(<<"ES384">>) -> {ec, sha384, <<"P-384">>, 48};
spec(<<"ES512">>) -> {ec, sha512, <<"P-521">>, 66};
spec(<<"Ed25519">>) -> {okp, <<"Ed25519">>};
spec(<<"Ed448">>) -> {okp, <<"Ed448">>};
spec(<<"EdDSA">>) -> {okp, any};
spec(_) -> false.

%%====================================================================
%% Key selection
%%====================================================================

usable(Alg, Spec, Kid, Jwk) ->
    fits(Spec, Jwk) andalso
        alg_ok(Alg, maps:get(<<"alg">>, Jwk, undefined)) andalso
        maps:get(<<"use">>, Jwk, <<"sig">>) =:= <<"sig">> andalso
        ops_ok(maps:get(<<"key_ops">>, Jwk, undefined)) andalso
        kid_ok(Kid, maps:get(<<"kid">>, Jwk, undefined)).

fits({rsa, _, _}, #{<<"kty">> := <<"RSA">>}) -> true;
fits({ec, _, Crv, _}, #{<<"kty">> := <<"EC">>, <<"crv">> := Crv}) -> true;
fits({okp, any}, #{<<"kty">> := <<"OKP">>, <<"crv">> := Crv}) -> is_ed_curve(Crv);
fits({okp, Crv}, #{<<"kty">> := <<"OKP">>, <<"crv">> := Crv}) -> true;
fits(_, _) -> false.

is_ed_curve(Crv) -> lists:member(Crv, [<<"Ed25519">>, <<"Ed448">>]).

%% The deprecated `EdDSA' name and the RFC 9864 names describe the same
%% keys, so a key labelled with one serves a token labelled with the other.
alg_ok(_Alg, undefined) -> true;
alg_ok(Alg, Alg) -> true;
alg_ok(<<"EdDSA">>, KeyAlg) -> is_ed_curve(KeyAlg);
alg_ok(Alg, <<"EdDSA">>) -> is_ed_curve(Alg);
alg_ok(_, _) -> false.

ops_ok(undefined) -> true;
ops_ok(Ops) when is_list(Ops) -> lists:member(<<"verify">>, Ops);
ops_ok(_) -> false.

kid_ok(undefined, _KeyKid) -> true;
kid_ok(Kid, Kid) -> true;
kid_ok(_, _) -> false.

try_keys(_Spec, _Input, _Sig, []) ->
    {error, bad_signature};
try_keys(Spec, Input, Sig, [Jwk | Rest]) ->
    case check(Spec, Input, Sig, Jwk) of
        true -> ok;
        false -> try_keys(Spec, Input, Sig, Rest)
    end.

%%====================================================================
%% Signatures
%%====================================================================

check(Spec, Input, Sig, Jwk) ->
    try
        check_sig(Spec, Input, Sig, Jwk)
    catch
        _:_ -> false
    end.

check_sig({rsa, Hash, Padding}, Input, Sig, Jwk) ->
    case rsa_key(Jwk) of
        {ok, Key} -> public_key:verify(Input, Hash, Sig, Key, rsa_opts(Padding, Hash));
        error -> false
    end;
check_sig({ec, Hash, Crv, Size}, Input, Sig, Jwk) ->
    case {ec_key(Crv, Size, Jwk), der_sig(Sig, Size)} of
        {{ok, Key}, {ok, Der}} -> public_key:verify(Input, Hash, Der, Key);
        _ -> false
    end;
check_sig({okp, _}, Input, Sig, Jwk) ->
    case ed_key(Jwk) of
        {ok, Key} -> public_key:verify(Input, none, Sig, Key);
        error -> false
    end.

%% RFC 7518 3.5: PSS with MGF1 on the same hash and a salt as long as it.
rsa_opts(pkcs1, _Hash) ->
    [];
rsa_opts(pss, Hash) ->
    [
        {rsa_padding, rsa_pkcs1_pss_padding},
        {rsa_pss_saltlen, hash_size(Hash)},
        {rsa_mgf1_md, Hash}
    ].

hash_size(sha256) -> 32;
hash_size(sha384) -> 48;
hash_size(sha512) -> 64.

rsa_key(#{<<"n">> := N64, <<"e">> := E64}) ->
    case {b64url(N64), b64url(E64)} of
        {{ok, NBin}, {ok, EBin}} ->
            N = binary:decode_unsigned(NBin),
            case N >= 1 bsl 2047 of
                true ->
                    {ok, #'RSAPublicKey'{
                        modulus = N, publicExponent = binary:decode_unsigned(EBin)
                    }};
                false ->
                    error
            end;
        _ ->
            error
    end;
rsa_key(_) ->
    error.

ec_key(Crv, Size, #{<<"x">> := X64, <<"y">> := Y64}) ->
    case {b64url(X64), b64url(Y64)} of
        {{ok, X}, {ok, Y}} when byte_size(X) =:= Size, byte_size(Y) =:= Size ->
            {ok, {#'ECPoint'{point = <<4, X/binary, Y/binary>>}, {namedCurve, curve_oid(Crv)}}};
        _ ->
            error
    end;
ec_key(_Crv, _Size, _) ->
    error.

curve_oid(<<"P-256">>) -> ?'secp256r1';
curve_oid(<<"P-384">>) -> ?'secp384r1';
curve_oid(<<"P-521">>) -> ?'secp521r1'.

ed_key(#{<<"crv">> := Crv, <<"x">> := X64}) ->
    case {Crv, b64url(X64)} of
        {<<"Ed25519">>, {ok, X}} when byte_size(X) =:= 32 ->
            {ok, {#'ECPoint'{point = X}, {namedCurve, ?'id-Ed25519'}}};
        {<<"Ed448">>, {ok, X}} when byte_size(X) =:= 57 ->
            {ok, {#'ECPoint'{point = X}, {namedCurve, ?'id-Ed448'}}};
        _ ->
            error
    end;
ed_key(_) ->
    error.

%% JWS ECDSA signatures are the raw r||s concatenation (RFC 7518 3.4);
%% `public_key:verify' wants a DER ECDSA-Sig-Value.
der_sig(Sig, Size) when byte_size(Sig) =:= 2 * Size ->
    <<R:Size/binary, S:Size/binary>> = Sig,
    {ok,
        public_key:der_encode('ECDSA-Sig-Value', #'ECDSA-Sig-Value'{
            r = binary:decode_unsigned(R), s = binary:decode_unsigned(S)
        })};
der_sig(_Sig, _Size) ->
    error.
