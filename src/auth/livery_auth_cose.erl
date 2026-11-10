-module(livery_auth_cose).
-moduledoc """
COSE public keys (RFC 9052, RFC 9053) for WebAuthn.

`public_key/1` turns a decoded COSE_Key (from `livery_cbor`) into an OTP
public key, and `verify/4` checks a WebAuthn signature with it.

Algorithms: ES256 (-7), ES384 (-35), ES512 (-36) and their fully
specified RFC 9864 names ESP256 (-9), ESP384 (-51), ESP512 (-52);
EdDSA (-8, Ed25519 only, as WebAuthn L3 section 5.8.5 requires),
Ed25519 (-19) and Ed448 (-53) from RFC 9864; RS256 (-257, RFC 8812) and
PS256 (-37). The key type, curve and algorithm must agree, and RSA keys
under 2048 bits are refused. WebAuthn ECDSA signatures are DER-encoded,
as `public_key:verify/4` takes them.
""".

-include_lib("public_key/include/public_key.hrl").

-export([public_key/1, verify/4, algorithms/0, ec_curve/1]).

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
algorithms() -> [-8, -19, -53, -7, -9, -35, -51, -36, -52, -257, -37].

-doc "The algorithm and OTP public key a COSE_Key describes.".
-spec public_key(term()) -> {ok, alg(), key()} | {error, term()}.
public_key(#{?KTY := 2, ?ALG := Alg, ?CRV := Crv, ?X := {bytes, X}, ?Y := {bytes, Y}}) ->
    case {ec_curve(Alg), Crv} of
        {{Crv, Oid, Size}, _} -> ec_key(Alg, Oid, Size, X, Y);
        _ -> {error, {unsupported_key, Alg, Crv}}
    end;
public_key(#{?KTY := 1, ?ALG := Alg, ?CRV := Crv, ?X := {bytes, X}}) ->
    case {Alg, Crv, byte_size(X)} of
        {A, 6, 32} when A =:= -8; A =:= -19 ->
            {ok, Alg, {#'ECPoint'{point = X}, {namedCurve, ?'id-Ed25519'}}};
        {-53, 7, 57} ->
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

check(Ed, Key, Data, Sig) when Ed =:= -8; Ed =:= -19; Ed =:= -53 ->
    public_key:verify(Data, none, Sig, Key);
check(-257, Key, Data, Sig) ->
    public_key:verify(Data, sha256, Sig, Key);
check(-37, Key, Data, Sig) ->
    public_key:verify(Data, sha256, Sig, Key, [
        {rsa_padding, rsa_pkcs1_pss_padding}, {rsa_pss_saltlen, 32}, {rsa_mgf1_md, sha256}
    ]);
check(Alg, Key, Data, Sig) ->
    case ec_curve(Alg) of
        {_, _, Size} -> public_key:verify(Data, ec_hash(Size), Sig, Key);
        undefined -> false
    end.

-doc """
The COSE curve, OTP curve OID and coordinate size an ECDSA algorithm
uses, or `undefined` for any other algorithm.
""".
-spec ec_curve(alg()) -> {integer(), tuple(), pos_integer()} | undefined.
ec_curve(Alg) when Alg =:= -7; Alg =:= -9 -> {1, ?'secp256r1', 32};
ec_curve(Alg) when Alg =:= -35; Alg =:= -51 -> {2, ?'secp384r1', 48};
ec_curve(Alg) when Alg =:= -36; Alg =:= -52 -> {3, ?'secp521r1', 66};
ec_curve(_) -> undefined.

ec_hash(32) -> sha256;
ec_hash(48) -> sha384;
ec_hash(66) -> sha512.

ec_key(Alg, CurveOid, Size, X, Y) when byte_size(X) =:= Size, byte_size(Y) =:= Size ->
    {ok, Alg, {#'ECPoint'{point = <<4, X/binary, Y/binary>>}, {namedCurve, CurveOid}}};
ec_key(Alg, _Curve, _Size, _X, _Y) ->
    {error, {bad_key_size, Alg}}.
