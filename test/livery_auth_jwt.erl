%% @doc Test helper that mints signed JWTs for livery_auth tests.
%%
%% `keypair/2' generates a key for any JWS algorithm livery accepts and
%% returns the private half with the public JWK. `mint/3' signs a compact
%% JWT; `mint_raw/3' signs exactly the header it is given, for tests that
%% need a header the defaults would fix.
-module(livery_auth_jwt).

-include_lib("public_key/include/public_key.hrl").

-export([
    rsa_keypair/0,
    rsa_keypair/1,
    ec_keypair/0,
    ec_keypair/1,
    keypair/2,
    rsa_keypair_bits/2,
    mint/3,
    mint_raw/3
]).

%%====================================================================
%% Keypairs -> {Key, Jwk}
%%====================================================================

rsa_keypair() -> rsa_keypair(<<"rsa-1">>).

rsa_keypair(Kid) -> keypair(<<"RS256">>, Kid).

ec_keypair() -> ec_keypair(<<"ec-1">>).

ec_keypair(Kid) -> keypair(<<"ES256">>, Kid).

rsa_keypair_bits(Kid, Bits) ->
    Priv = public_key:generate_key({rsa, Bits, 65537}),
    {{<<"RS256">>, Priv}, rsa_jwk(Priv, Kid, <<"RS256">>)}.

keypair(<<"RS", _/binary>> = Alg, Kid) ->
    Priv = public_key:generate_key({rsa, 2048, 65537}),
    {{Alg, Priv}, rsa_jwk(Priv, Kid, Alg)};
keypair(<<"PS", _/binary>> = Alg, Kid) ->
    Priv = public_key:generate_key({rsa, 2048, 65537}),
    {{Alg, Priv}, rsa_jwk(Priv, Kid, Alg)};
keypair(<<"ES", _/binary>> = Alg, Kid) ->
    {Curve, Crv, Size} = ec_curve(Alg),
    Priv = public_key:generate_key({namedCurve, Curve}),
    #'ECPrivateKey'{publicKey = <<4, X:Size/binary, Y:Size/binary>>} = Priv,
    Jwk = #{
        <<"kty">> => <<"EC">>,
        <<"kid">> => Kid,
        <<"alg">> => Alg,
        <<"crv">> => Crv,
        <<"x">> => b64url(X),
        <<"y">> => b64url(Y)
    },
    {{Alg, Priv}, Jwk};
keypair(Alg, Kid) when Alg =:= <<"Ed25519">>; Alg =:= <<"Ed448">> ->
    Curve =
        case Alg of
            <<"Ed25519">> -> ed25519;
            <<"Ed448">> -> ed448
        end,
    Priv = public_key:generate_key({namedCurve, Curve}),
    #'ECPrivateKey'{publicKey = X} = Priv,
    Jwk = #{
        <<"kty">> => <<"OKP">>,
        <<"kid">> => Kid,
        <<"alg">> => Alg,
        <<"crv">> => Alg,
        <<"x">> => b64url(X)
    },
    {{Alg, Priv}, Jwk}.

rsa_jwk(#'RSAPrivateKey'{modulus = N, publicExponent = E}, Kid, Alg) ->
    #{
        <<"kty">> => <<"RSA">>,
        <<"kid">> => Kid,
        <<"alg">> => Alg,
        <<"n">> => b64url(binary:encode_unsigned(N)),
        <<"e">> => b64url(binary:encode_unsigned(E))
    }.

ec_curve(<<"ES256">>) -> {secp256r1, <<"P-256">>, 32};
ec_curve(<<"ES384">>) -> {secp384r1, <<"P-384">>, 48};
ec_curve(<<"ES512">>) -> {secp521r1, <<"P-521">>, 66}.

%%====================================================================
%% Minting
%%====================================================================

%% @doc Build a signed compact JWT. `HeaderExtra' is merged over the
%% defaults (`alg' from the key, `typ' JWT); the key's own `kid' is not
%% added, pass it in `HeaderExtra' when the test needs one.
mint({Alg, _} = Key, HeaderExtra, Claims) ->
    Header = maps:merge(#{<<"alg">> => Alg, <<"typ">> => <<"JWT">>}, HeaderExtra),
    mint_raw(Key, Header, Claims).

%% @doc Sign `Header' and `Claims' with `livery_auth_jose:sign/3'.
mint_raw(Key, Header, Claims) ->
    livery_auth_jose:sign(Key, Header, Claims).

b64url(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).
