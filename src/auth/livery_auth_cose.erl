-module(livery_auth_cose).
-moduledoc """
COSE public keys (RFC 9052, RFC 9053) for WebAuthn.

`public_key/1` turns a decoded COSE_Key (from `livery_cbor`) into an OTP
public key, and `verify/4` checks a WebAuthn signature with it.

Algorithms: ES256 (-7), ES384 (-35), ES512 (-36), EdDSA (-8, Ed25519 or
Ed448 from the key's curve), Ed25519 (-19, RFC 9864), RS256 (-257,
RFC 8812) and PS256 (-37). The key type, curve and algorithm must agree,
and RSA keys under 2048 bits are refused. WebAuthn ECDSA signatures are
DER-encoded, as `public_key:verify/4` takes them.
""".

-include_lib("public_key/include/public_key.hrl").

-export([public_key/1, verify/4, algorithms/0]).

-type alg() :: integer().
-type key() :: term().

-export_type([alg/0, key/0]).

%% COSE_Key labels (RFC 9052 7.1, RFC 9053 7)
-define(KTY, 1).
-define(ALG, 3).
-define(CRV, -1).
-define(X, -2).
-define(Y, -3).
-define(RSA_N, -1).
-define(RSA_E, -2).

-doc "The COSE algorithms Livery verifies, in preference order.".
-spec algorithms() -> [alg()].
algorithms() -> [-8, -19, -7, -35, -36, -257, -37].

-doc "The algorithm and OTP public key a COSE_Key describes.".
-spec public_key(term()) -> {ok, alg(), key()} | {error, term()}.
public_key(#{?KTY := 2, ?ALG := Alg, ?CRV := Crv, ?X := {bytes, X}, ?Y := {bytes, Y}}) ->
    case {Alg, Crv} of
        {-7, 1} -> ec_key(Alg, ?'secp256r1', 32, X, Y);
        {-35, 2} -> ec_key(Alg, ?'secp384r1', 48, X, Y);
        {-36, 3} -> ec_key(Alg, ?'secp521r1', 66, X, Y);
        _ -> {error, {unsupported_key, Alg, Crv}}
    end;
public_key(#{?KTY := 1, ?ALG := Alg, ?CRV := Crv, ?X := {bytes, X}}) ->
    case {Alg, Crv, byte_size(X)} of
        {A, 6, 32} when A =:= -8; A =:= -19 ->
            {ok, Alg, {#'ECPoint'{point = X}, {namedCurve, ?'id-Ed25519'}}};
        {-8, 7, 57} ->
            {ok, Alg, {#'ECPoint'{point = X}, {namedCurve, ?'id-Ed448'}}};
        _ ->
            {error, {unsupported_key, Alg, Crv}}
    end;
public_key(#{?KTY := 3, ?ALG := Alg, ?RSA_N := {bytes, NBin}, ?RSA_E := {bytes, EBin}}) when
    Alg =:= -257; Alg =:= -37
->
    N = binary:decode_unsigned(NBin),
    case N >= 1 bsl 2047 of
        true ->
            {ok, Alg, #'RSAPublicKey'{modulus = N, publicExponent = binary:decode_unsigned(EBin)}};
        false ->
            {error, rsa_key_too_short}
    end;
public_key(_) ->
    {error, unsupported_key}.

-doc "Check a WebAuthn signature over `Data`.".
-spec verify(alg(), key(), binary(), binary()) -> boolean().
verify(Alg, Key, Data, Sig) ->
    try
        check(Alg, Key, Data, Sig)
    catch
        _:_ -> false
    end.

check(-7, Key, Data, Sig) ->
    public_key:verify(Data, sha256, Sig, Key);
check(-35, Key, Data, Sig) ->
    public_key:verify(Data, sha384, Sig, Key);
check(-36, Key, Data, Sig) ->
    public_key:verify(Data, sha512, Sig, Key);
check(Ed, Key, Data, Sig) when Ed =:= -8; Ed =:= -19 -> public_key:verify(Data, none, Sig, Key);
check(-257, Key, Data, Sig) ->
    public_key:verify(Data, sha256, Sig, Key);
check(-37, Key, Data, Sig) ->
    public_key:verify(Data, sha256, Sig, Key, [
        {rsa_padding, rsa_pkcs1_pss_padding}, {rsa_pss_saltlen, 32}, {rsa_mgf1_md, sha256}
    ]);
check(_, _Key, _Data, _Sig) ->
    false.

ec_key(Alg, CurveOid, Size, X, Y) when byte_size(X) =:= Size, byte_size(Y) =:= Size ->
    {ok, Alg, {#'ECPoint'{point = <<4, X/binary, Y/binary>>}, {namedCurve, CurveOid}}};
ec_key(Alg, _Curve, _Size, _X, _Y) ->
    {error, {bad_key_size, Alg}}.
