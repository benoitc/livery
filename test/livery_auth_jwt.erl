%% @doc Test helper that mints signed JWTs for livery_auth tests.
%%
%% Generates RSA and EC P-256 keypairs, exposes the public half as
%% a JWK map, and signs compact JWTs with RS256 / ES256.
-module(livery_auth_jwt).

-include_lib("public_key/include/public_key.hrl").

-export([
    rsa_keypair/0,
    rsa_keypair/1,
    ec_keypair/0,
    ec_keypair/1,
    mint/3
]).

%%====================================================================
%% Keypairs -> {PrivKey, Jwk}
%%====================================================================

rsa_keypair() -> rsa_keypair(<<"rsa-1">>).

rsa_keypair(Kid) ->
    Priv = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{modulus = N, publicExponent = E} = Priv,
    Jwk = #{
        <<"kty">> => <<"RSA">>,
        <<"kid">> => Kid,
        <<"alg">> => <<"RS256">>,
        <<"n">> => b64url(binary:encode_unsigned(N)),
        <<"e">> => b64url(binary:encode_unsigned(E))
    },
    {{rs256, Priv}, Jwk}.

ec_keypair() -> ec_keypair(<<"ec-1">>).

ec_keypair(Kid) ->
    Priv = public_key:generate_key({namedCurve, secp256r1}),
    #'ECPrivateKey'{publicKey = <<4, X:32/binary, Y:32/binary>>} = Priv,
    Jwk = #{
        <<"kty">> => <<"EC">>,
        <<"kid">> => Kid,
        <<"alg">> => <<"ES256">>,
        <<"crv">> => <<"P-256">>,
        <<"x">> => b64url(X),
        <<"y">> => b64url(Y)
    },
    {{es256, Priv}, Jwk}.

%%====================================================================
%% Minting
%%====================================================================

%% @doc Build a signed compact JWT.
%%
%% `Key' is `{rs256, RSAPriv}' or `{es256, ECPriv}'. `Header' and
%% `Claims' are maps that get merged with sensible defaults
%% (`alg`, `typ`, and the key id).
mint({Alg, _} = Key, HeaderExtra, Claims) ->
    Header = maps:merge(
        #{
            <<"alg">> => alg_name(Alg),
            <<"typ">> => <<"JWT">>
        },
        HeaderExtra
    ),
    H64 = b64url(iolist_to_binary(json:encode(Header))),
    P64 = b64url(iolist_to_binary(json:encode(Claims))),
    SigningInput = <<H64/binary, ".", P64/binary>>,
    Sig = sign(Key, SigningInput),
    S64 = b64url(Sig),
    <<SigningInput/binary, ".", S64/binary>>.

%%====================================================================
%% Signing
%%====================================================================

sign({rs256, Priv}, SigningInput) ->
    public_key:sign(SigningInput, sha256, Priv);
sign({es256, Priv}, SigningInput) ->
    DerSig = public_key:sign(SigningInput, sha256, Priv),
    #'ECDSA-Sig-Value'{r = R, s = S} =
        public_key:der_decode('ECDSA-Sig-Value', DerSig),
    <<(pad32(binary:encode_unsigned(R)))/binary, (pad32(binary:encode_unsigned(S)))/binary>>.

alg_name(rs256) -> <<"RS256">>;
alg_name(es256) -> <<"ES256">>.

pad32(B) when byte_size(B) =:= 32 -> B;
pad32(B) when byte_size(B) < 32 ->
    Pad = 32 - byte_size(B),
    <<0:(Pad * 8), B/binary>>;
pad32(<<0, Rest/binary>>) when byte_size(Rest) =:= 32 ->
    %% encode_unsigned may prepend a leading zero for the high bit.
    Rest.

b64url(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).
