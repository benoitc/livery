-module(livery_auth_webauthn_attest).
-moduledoc """
WebAuthn attestation statements (WebAuthn Level 3, sections 8.2 and 8.7).

`verify/2` checks the attestation statement of a new credential:

- `none`: an empty statement; nothing is claimed about the
  authenticator. Synced passkeys (Apple, Google, password managers) send
  this.
- `packed` without `x5c` (self attestation): signed by the credential's
  own key, with the credential's algorithm.
- `packed` with `x5c`: signed by the leaf certificate with an `alg`
  that fits its key, the leaf meeting section 8.2.1 (version 3; subject
  with C, O, `OU=Authenticator Attestation` and CN; Basic Constraints
  with CA false; an AAGUID extension, when present, not critical and
  equal to the credential's) and chaining to one of the
  `attestation_roots` (DER) you configure.
- any other format: refused, or reported as `unattested` when
  `allow_unattested => true`.

With `attestation_roots` set, only the last kind is accepted: `none`
and self attestation say nothing about the authenticator, so they are
refused as `{untrusted_attestation, none | self}`, unless
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
verify(Att, Opts) ->
    case statement(Att, Opts) of
        {ok, Kind} when Kind =:= none; Kind =:= self ->
            case trusted_only(Opts) of
                true -> {error, {untrusted_attestation, Kind}};
                false -> {ok, Kind}
            end;
        Other ->
            Other
    end.

trusted_only(#{allow_unattested := true}) -> false;
trusted_only(#{attestation_roots := [_ | _]}) -> true;
trusted_only(_Opts) -> false.

statement(#{fmt := <<"none">>, att_stmt := Stmt}, _Opts) when map_size(Stmt) =:= 0 ->
    {ok, none};
statement(#{fmt := <<"none">>}, _Opts) ->
    {error, {invalid_attestation, none}};
statement(#{fmt := <<"packed">>, att_stmt := Stmt} = Att, Opts) ->
    packed(Stmt, Att, Opts);
statement(#{fmt := Fmt}, #{allow_unattested := true}) when is_binary(Fmt) ->
    {ok, unattested};
statement(#{fmt := Fmt}, _Opts) ->
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

%% The statement's `alg' must fit the leaf's key (curve, RSA, Ed25519):
%% otherwise a signature could be checked with a hash the key never used.
leaf_signature(Alg, Sig, Data, Cert) ->
    case cert_key(Cert) of
        {Kind, Key} ->
            case fits(Alg, Kind) of
                true -> leaf_verify(Alg, Key, Data, Sig);
                false -> {error, {invalid_attestation, alg}}
            end;
        error ->
            {error, {invalid_attestation, certificate}}
    end.

leaf_verify(Alg, Key, Data, Sig) ->
    case livery_auth_cose:verify(Alg, Key, Data, Sig) of
        true -> ok;
        false -> {error, {invalid_attestation, signature}}
    end.

fits(Alg, {ec, Oid}) ->
    case livery_auth_cose:ec_curve(Alg) of
        {_, Oid, _} -> true;
        _ -> false
    end;
fits(Alg, rsa) ->
    Alg =:= -257 orelse Alg =:= -37;
fits(Alg, ed25519) ->
    Alg =:= -8 orelse Alg =:= -19.

cert_key(#'OTPCertificate'{tbsCertificate = Tbs}) ->
    #'OTPSubjectPublicKeyInfo'{algorithm = AlgId, subjectPublicKey = Key} =
        Tbs#'OTPTBSCertificate'.subjectPublicKeyInfo,
    case {AlgId, Key} of
        {#'PublicKeyAlgorithm'{parameters = {namedCurve, Oid} = Params}, #'ECPoint'{}} ->
            {{ec, Oid}, {Key, Params}};
        {_, #'RSAPublicKey'{}} ->
            {rsa, Key};
        {#'PublicKeyAlgorithm'{algorithm = ?'id-Ed25519'}, #'ECPoint'{}} ->
            {ed25519, {Key, {namedCurve, ?'id-Ed25519'}}};
        _ ->
            error
    end.

%% WebAuthn L3 8.2.1
leaf_requirements(#'OTPCertificate'{tbsCertificate = Tbs}, Aaguid) ->
    Exts =
        case Tbs#'OTPTBSCertificate'.extensions of
            L when is_list(L) -> L;
            _ -> []
        end,
    Subject = subject(Tbs),
    Checks = [
        {Tbs#'OTPTBSCertificate'.version =:= v3, version},
        {country(Subject), subject_c},
        {has(?'id-at-organizationName', Subject), subject_o},
        {
            lists:member(
                <<"Authenticator Attestation">>, values(?'id-at-organizationalUnitName', Subject)
            ),
            subject_ou
        },
        {has(?'id-at-commonName', Subject), subject_cn},
        {not_ca(Exts), basic_constraints},
        {aaguid_ok(Exts, Aaguid), aaguid}
    ],
    case [What || {false, What} <- Checks] of
        [] -> ok;
        [What | _] -> {error, {invalid_attestation, What}}
    end.

subject(#'OTPTBSCertificate'{subject = {rdnSequence, Rdns}}) ->
    [{T, text(V)} || Rdn <- Rdns, #'AttributeTypeAndValue'{type = T, value = V} <- Rdn].

values(Type, Subject) -> [V || {T, V} <- Subject, T =:= Type].

has(Type, Subject) -> lists:any(fun(V) -> V =/= <<>> end, values(Type, Subject)).

%% ISO 3166 code: two letters.
country(Subject) ->
    lists:any(
        fun(V) -> byte_size(V) =:= 2 andalso lists:all(fun is_letter/1, binary_to_list(V)) end,
        values(?'id-at-countryName', Subject)
    ).

is_letter(C) -> (C >= $A andalso C =< $Z) orelse (C >= $a andalso C =< $z).

text({_Tag, V}) -> text(V);
text(V) when is_binary(V) -> V;
text(V) when is_list(V) -> unicode:characters_to_binary(V);
text(_) -> <<>>.

%% Basic Constraints must be there, with CA false.
not_ca(Exts) ->
    case lists:keyfind(?'id-ce-basicConstraints', #'Extension'.extnID, Exts) of
        #'Extension'{extnValue = #'BasicConstraints'{cA = true}} -> false;
        #'Extension'{extnValue = #'BasicConstraints'{}} -> true;
        _ -> false
    end.

aaguid_ok(Exts, Aaguid) ->
    case lists:keyfind(?AAGUID_EXT, #'Extension'.extnID, Exts) of
        false -> true;
        #'Extension'{critical = true} -> false;
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
