-module(livery_auth_webauthn_attest).
-moduledoc """
WebAuthn attestation statements (WebAuthn Level 3, sections 8.2 and 8.7).

`verify/2` checks the attestation statement of a new credential:

- `none`: an empty statement; nothing is claimed about the
  authenticator. Synced passkeys (Apple, Google, password managers) send
  this.
- `packed` without `x5c` (self attestation): signed by the credential's
  own key, with the credential's algorithm.
- `packed` with `x5c`: signed by the leaf certificate, which must meet
  section 8.2.1 (version 3, subject `OU=Authenticator Attestation`,
  not a CA, AAGUID extension equal to the credential's when present) and
  chain to one of the `attestation_roots` (DER) you configure.
- any other format: refused, or reported as `unattested` when
  `allow_unattested => true`.

Deviations: only `none` and `packed` are verified, and the FIDO
Metadata Service is not consulted. See AGENTS.md, Known deviations.
""".

-include_lib("public_key/include/public_key.hrl").

-export([verify/2]).

-type result() :: none | self | {x5c, binary()} | unattested.

-export_type([result/0]).

%% id-fido-gen-ce-aaguid
-define(AAGUID_EXT, {1, 3, 6, 1, 4, 1, 45724, 1, 1, 4}).

-doc """
Verify the statement in `Att`: `fmt`, `att_stmt`, `auth_data` (raw),
`client_data_hash`, and the credential's `alg`, `key` and `aaguid`.
""".
-spec verify(map(), map()) -> {ok, result()} | {error, term()}.
verify(#{fmt := <<"none">>, att_stmt := Stmt}, _Opts) when map_size(Stmt) =:= 0 ->
    {ok, none};
verify(#{fmt := <<"none">>}, _Opts) ->
    {error, {invalid_attestation, none}};
verify(#{fmt := <<"packed">>, att_stmt := Stmt} = Att, Opts) ->
    packed(Stmt, Att, Opts);
verify(#{fmt := Fmt}, #{allow_unattested := true}) when is_binary(Fmt) ->
    {ok, unattested};
verify(#{fmt := Fmt}, _Opts) ->
    {error, {unsupported_attestation, Fmt}}.

packed(#{<<"alg">> := Alg, <<"sig">> := {bytes, Sig}} = Stmt, Att, Opts) ->
    Data = <<(maps:get(auth_data, Att))/binary, (maps:get(client_data_hash, Att))/binary>>,
    case maps:find(<<"x5c">>, Stmt) of
        error ->
            self_attestation(Alg, Sig, Data, Att);
        {ok, [{bytes, Leaf} | Rest]} ->
            full(Alg, Sig, Data, Leaf, [B || {bytes, B} <- Rest], Att, Opts);
        {ok, _} ->
            {error, {invalid_attestation, x5c}}
    end;
packed(_Stmt, _Att, _Opts) ->
    {error, {invalid_attestation, packed}}.

self_attestation(Alg, Sig, Data, #{alg := Alg, key := Key}) ->
    case livery_auth_cose:verify(Alg, Key, Data, Sig) of
        true -> {ok, self};
        false -> {error, {invalid_attestation, signature}}
    end;
self_attestation(_Alg, _Sig, _Data, _Att) ->
    {error, {invalid_attestation, alg}}.

full(Alg, Sig, Data, Leaf, Chain, #{aaguid := Aaguid}, Opts) ->
    try public_key:pkix_decode_cert(Leaf, otp) of
        Cert ->
            Steps = [
                fun() -> leaf_signature(Alg, Sig, Data, Cert) end,
                fun() -> leaf_requirements(Cert, Aaguid) end,
                fun() -> chain(Leaf, Chain, maps:get(attestation_roots, Opts, [])) end
            ],
            case run(Steps) of
                ok -> {ok, {x5c, Leaf}};
                {error, _} = E -> E
            end
    catch
        _:_ -> {error, {invalid_attestation, certificate}}
    end.

run([]) ->
    ok;
run([Step | Rest]) ->
    case Step() of
        ok -> run(Rest);
        {error, _} = E -> E
    end.

leaf_signature(Alg, Sig, Data, Cert) ->
    Key = cert_key(Cert),
    Digest =
        case Alg of
            -7 -> sha256;
            -35 -> sha384;
            -36 -> sha512;
            -257 -> sha256;
            _ -> undefined
        end,
    case Digest =/= undefined andalso catch_verify(Data, Digest, Sig, Key) of
        true -> ok;
        _ -> {error, {invalid_attestation, signature}}
    end.

catch_verify(Data, Digest, Sig, Key) ->
    try
        public_key:verify(Data, Digest, Sig, Key)
    catch
        _:_ -> false
    end.

cert_key(#'OTPCertificate'{tbsCertificate = Tbs}) ->
    #'OTPSubjectPublicKeyInfo'{algorithm = AlgId, subjectPublicKey = Key} =
        Tbs#'OTPTBSCertificate'.subjectPublicKeyInfo,
    case AlgId of
        #'PublicKeyAlgorithm'{parameters = {namedCurve, _} = Params} -> {Key, Params};
        _ -> Key
    end.

%% WebAuthn L3 8.2.1
leaf_requirements(#'OTPCertificate'{tbsCertificate = Tbs}, Aaguid) ->
    Exts =
        case Tbs#'OTPTBSCertificate'.extensions of
            L when is_list(L) -> L;
            _ -> []
        end,
    Checks = [
        {Tbs#'OTPTBSCertificate'.version =:= v3, version},
        {lists:member(<<"Authenticator Attestation">>, subject_ous(Tbs)), subject_ou},
        {not is_ca(Exts), basic_constraints},
        {aaguid_ok(Exts, Aaguid), aaguid}
    ],
    case [What || {false, What} <- Checks] of
        [] -> ok;
        [What | _] -> {error, {invalid_attestation, What}}
    end.

subject_ous(#'OTPTBSCertificate'{subject = {rdnSequence, Rdns}}) ->
    [
        text(V)
     || Rdn <- Rdns,
        #'AttributeTypeAndValue'{type = ?'id-at-organizationalUnitName', value = V} <- Rdn
    ].

text({_Tag, V}) -> text(V);
text(V) when is_binary(V) -> V;
text(V) when is_list(V) -> unicode:characters_to_binary(V).

is_ca(Exts) ->
    case lists:keyfind(?'id-ce-basicConstraints', #'Extension'.extnID, Exts) of
        #'Extension'{extnValue = #'BasicConstraints'{cA = true}} -> true;
        _ -> false
    end.

aaguid_ok(Exts, Aaguid) ->
    case lists:keyfind(?AAGUID_EXT, #'Extension'.extnID, Exts) of
        false -> true;
        #'Extension'{extnValue = <<4, 16, Value:16/binary>>} -> Value =:= Aaguid;
        #'Extension'{extnValue = Value} -> Value =:= Aaguid
    end.

%% The leaf and intermediates in `x5c' must lead to a configured root.
chain(_Leaf, _Chain, []) ->
    {error, {invalid_attestation, no_attestation_roots}};
chain(Leaf, Chain, Roots) ->
    Path = lists:reverse(Chain) ++ [Leaf],
    case lists:any(fun(Root) -> valid_path(Root, Path) end, Roots) of
        true -> ok;
        false -> {error, {invalid_attestation, untrusted_chain}}
    end.

valid_path(Root, Path) ->
    try public_key:pkix_path_validation(Root, Path, []) of
        {ok, _} -> true;
        {error, _} -> false
    catch
        _:_ -> false
    end.
