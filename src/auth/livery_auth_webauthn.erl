-module(livery_auth_webauthn).
-moduledoc """
Passkey (WebAuthn Level 3) ceremonies, without I/O.

Two ceremonies, each in two steps: the server sends options with a fresh
challenge, the browser asks the authenticator, the server verifies the
answer.

- Registration: `creation_options/2`, then `verify_registration/2`,
  which returns the credential to store.
- Sign-in: `request_options/1`, then `verify_authentication/3` with the
  stored credential, which returns the new signature counter to store.

Options are JSON-ready maps for the browser's
`PublicKeyCredential.parseCreationOptionsFromJSON` and
`parseRequestOptionsFromJSON`; responses are what `credential.toJSON()`
gives, decoded. Both use unpadded base64url for binary fields.

The checks follow sections 7.1 and 7.2: the client data type, the
challenge, the origin (one of `origins`), cross-origin calls (refused
unless `allow_cross_origin => true`, and then the framing page,
`topOrigin`, must be one of `top_origins`), the RP ID hash, the user-present
flag, the user-verified flag when `user_verification => required`, the
backup flags, the user handle on sign-in (required, unless
`user_identified => true` says you picked the user before the
ceremony, as for a second factor), the algorithm, the attestation (`livery_auth_webauthn_attest`),
the signature, and the signature counter.

Each challenge must be used once. `livery_auth_passkey` does that for
you; when you call these functions yourself, keep the challenge on the
server and drop it as soon as a response arrives.
""".

-export([creation_options/2, request_options/1, verify_registration/2, verify_authentication/3]).

-define(UP, 16#01).
-define(UV, 16#04).
-define(BE, 16#08).
-define(BS, 16#10).
-define(AT, 16#40).
-define(ED, 16#80).

-type credential() :: #{
    id := binary(),
    public_key := binary(),
    sign_count := non_neg_integer(),
    backup_eligible := boolean(),
    backup_state := boolean(),
    user_verified := boolean(),
    aaguid := binary(),
    transports := [binary()],
    attestation := livery_auth_webauthn_attest:result()
}.

-export_type([credential/0]).

%%====================================================================
%% Options
%%====================================================================

-doc """
Registration options for `User` (`id`, a stable opaque handle of at most
64 bytes, `name`, `display_name`). Returns the raw challenge, to keep for
the verify step, and the options. `Opts`: `rp_id` and `rp_name`
(required), `exclude` (credential ids the user already has),
`user_verification` and `resident_key` (`required`, `preferred` default,
`discouraged`), `attestation` (`none` default or `direct`), `timeout` (ms),
`algorithms` (COSE ids).
""".
-spec creation_options(map(), map()) -> {binary(), map()}.
creation_options(#{id := UserId, name := Name} = User, Opts) when byte_size(UserId) =< 64 ->
    Challenge = crypto:strong_rand_bytes(32),
    Options = #{
        <<"rp">> => #{<<"id">> => maps:get(rp_id, Opts), <<"name">> => maps:get(rp_name, Opts)},
        <<"user">> => #{
            <<"id">> => b64(UserId),
            <<"name">> => Name,
            <<"displayName">> => maps:get(display_name, User, Name)
        },
        <<"challenge">> => b64(Challenge),
        <<"pubKeyCredParams">> => [
            #{<<"type">> => <<"public-key">>, <<"alg">> => A}
         || A <- maps:get(algorithms, Opts, livery_auth_cose:algorithms())
        ],
        <<"excludeCredentials">> => descriptors(maps:get(exclude, Opts, [])),
        <<"authenticatorSelection">> => #{
            <<"residentKey">> => atom_to_binary(maps:get(resident_key, Opts, preferred)),
            <<"userVerification">> => atom_to_binary(maps:get(user_verification, Opts, preferred))
        },
        <<"attestation">> => atom_to_binary(maps:get(attestation, Opts, none)),
        <<"timeout">> => maps:get(timeout, Opts, 300000)
    },
    {Challenge, Options}.

-doc """
Sign-in options. With no `allow` (credential ids), any passkey for the
RP can answer (discoverable credentials, no username). `Opts`: `rp_id`
(required), `allow`, `user_verification`, `timeout`.
""".
-spec request_options(map()) -> {binary(), map()}.
request_options(Opts) ->
    Challenge = crypto:strong_rand_bytes(32),
    Options = #{
        <<"rpId">> => maps:get(rp_id, Opts),
        <<"challenge">> => b64(Challenge),
        <<"allowCredentials">> => descriptors(maps:get(allow, Opts, [])),
        <<"userVerification">> => atom_to_binary(maps:get(user_verification, Opts, preferred)),
        <<"timeout">> => maps:get(timeout, Opts, 300000)
    },
    {Challenge, Options}.

descriptors(Ids) ->
    [#{<<"type">> => <<"public-key">>, <<"id">> => b64(Id)} || Id <- Ids].

%%====================================================================
%% Registration (section 7.1)
%%====================================================================

-doc """
Verify a registration response against `Expected`: `challenge` (raw),
`rp_id`, `origins`, and optionally `user_verification`, `algorithms`,
`allow_cross_origin`, `top_origins`, `attestation_roots`,
`allow_unattested`.
""".
-spec verify_registration(map(), map()) -> {ok, credential()} | {error, term()}.
verify_registration(
    #{<<"type">> := <<"public-key">>, <<"rawId">> := RawId, <<"response">> := Resp}, Expected
) ->
    maybe
        {ok, ClientDataJSON} ?= field(<<"clientDataJSON">>, Resp),
        {ok, AttObjBin} ?= field(<<"attestationObject">>, Resp),
        ok ?= client_data(ClientDataJSON, <<"webauthn.create">>, Expected),
        {ok, Fmt, Stmt, AuthData} ?= attestation_object(AttObjBin),
        {ok, Auth} ?= auth_data(AuthData),
        ok ?= flags(Auth, Expected, registration),
        #{cred_id := CredId, cose_key := CoseBin} ?= Auth,
        ok ?= same(b64_decode(RawId), {ok, CredId}, credential_id),
        {ok, Alg, Key} ?= credential_key(CoseBin, Expected),
        Att = #{
            fmt => Fmt,
            att_stmt => Stmt,
            auth_data => AuthData,
            client_data_hash => crypto:hash(sha256, ClientDataJSON),
            alg => Alg,
            key => Key,
            aaguid => maps:get(aaguid, Auth)
        },
        {ok, Attestation} ?= livery_auth_webauthn_attest:verify(Att, Expected),
        {ok, credential(Auth, Resp, Attestation)}
    else
        {error, _} = E -> E;
        _ -> {error, malformed}
    end;
verify_registration(_Response, _Expected) ->
    {error, malformed}.

attestation_object(Bin) ->
    case cbor(Bin) of
        {ok, #{<<"fmt">> := Fmt, <<"attStmt">> := #{} = Stmt, <<"authData">> := {bytes, AuthData}},
            <<>>} ->
            {ok, Fmt, Stmt, AuthData};
        _ ->
            {error, malformed_attestation_object}
    end.

credential_key(CoseBin, Expected) ->
    maybe
        {ok, CoseKey, <<>>} ?= cbor(CoseBin),
        {ok, Alg, Key} ?= livery_auth_cose:public_key(CoseKey),
        ok ?= allowed_alg(Alg, Expected),
        {ok, Alg, Key}
    end.

credential(#{cred_id := CredId, cose_key := CoseBin} = Auth, Resp, Attestation) ->
    #{
        id => CredId,
        public_key => CoseBin,
        sign_count => maps:get(sign_count, Auth),
        backup_eligible => maps:get(be, Auth),
        backup_state => maps:get(bs, Auth),
        user_verified => maps:get(uv, Auth),
        aaguid => maps:get(aaguid, Auth),
        transports => [T || T <- maps:get(<<"transports">>, Resp, []), is_binary(T)],
        attestation => Attestation
    }.

%%====================================================================
%% Authentication (section 7.2)
%%====================================================================

-doc """
Verify a sign-in response with the stored `Credential` (`id`,
`public_key`, `sign_count`, `backup_eligible`, and `user_handle` when
known) against `Expected` (`challenge`, `rp_id`, `origins`, optionally
`user_verification`, `allow_cross_origin`, `top_origins`,
`user_identified`). Returns what to update:
`sign_count`, `backup_state`, `user_verified`.
""".
-spec verify_authentication(map(), map(), map()) -> {ok, map()} | {error, term()}.
verify_authentication(
    #{<<"type">> := <<"public-key">>, <<"rawId">> := RawId, <<"response">> := Resp},
    Credential,
    Expected
) ->
    maybe
        ok ?= same(b64_decode(RawId), {ok, maps:get(id, Credential)}, credential_id),
        ok ?= user_handle(maps:get(<<"userHandle">>, Resp, null), Credential, Expected),
        {ok, ClientDataJSON} ?= field(<<"clientDataJSON">>, Resp),
        {ok, AuthData} ?= field(<<"authenticatorData">>, Resp),
        {ok, Sig} ?= field(<<"signature">>, Resp),
        ok ?= client_data(ClientDataJSON, <<"webauthn.get">>, Expected),
        {ok, Auth} ?= auth_data(AuthData),
        ok ?= flags(Auth, Expected, authentication),
        ok ?= same(maps:get(be, Auth), maps:get(backup_eligible, Credential), backup_eligible),
        Signed = <<AuthData/binary, (crypto:hash(sha256, ClientDataJSON))/binary>>,
        ok ?= stored_signature(maps:get(public_key, Credential), Signed, Sig),
        ok ?= counter(maps:get(sign_count, Auth), maps:get(sign_count, Credential)),
        {ok, #{
            sign_count => maps:get(sign_count, Auth),
            backup_state => maps:get(bs, Auth),
            user_verified => maps:get(uv, Auth)
        }}
    else
        {error, _} = E -> E;
        _ -> {error, malformed}
    end;
verify_authentication(_Response, _Credential, _Expected) ->
    {error, malformed}.

%%====================================================================
%% Checks
%%====================================================================

%% L3 7.1 step 5: UTF-8 decode, which drops a byte order mark.
client_data(<<16#EF, 16#BB, 16#BF, Json/binary>>, Type, Expected) ->
    client_data(Json, Type, Expected);
client_data(Json, Type, #{challenge := Challenge} = Expected) ->
    Want = b64(Challenge),
    try json:decode(Json) of
        #{<<"type">> := Type, <<"challenge">> := Want, <<"origin">> := Origin} = CD when
            is_binary(Origin)
        ->
            maybe
                ok ?=
                    origin(
                        Origin,
                        maps:get(origins, Expected),
                        maps:get(<<"crossOrigin">>, CD, false),
                        Expected
                    ),
                top_origin(maps:get(<<"topOrigin">>, CD, undefined), Expected)
            end;
        #{<<"type">> := Type, <<"challenge">> := _} ->
            {error, challenge_mismatch};
        #{<<"type">> := _} ->
            {error, wrong_type};
        _ ->
            {error, malformed}
    catch
        _:_ -> {error, malformed}
    end.

origin(Origin, Origins, Cross, Expected) ->
    case {lists:member(Origin, Origins), Cross} of
        {false, _} ->
            {error, origin_mismatch};
        {true, true} ->
            case maps:get(allow_cross_origin, Expected, false) of
                true -> ok;
                false -> {error, cross_origin}
            end;
        {true, _} ->
            ok
    end.

%% L3 7.1 step 11, 7.2 step 15: a `topOrigin' is the page that framed
%% the ceremony; it must be one the application expects to frame it.
top_origin(undefined, _Expected) ->
    ok;
top_origin(Top, #{allow_cross_origin := true} = Expected) ->
    case lists:member(Top, maps:get(top_origins, Expected, [])) of
        true -> ok;
        false -> {error, top_origin_mismatch}
    end;
top_origin(_Top, _Expected) ->
    {error, top_origin_mismatch}.

flags(#{rp_id_hash := Hash} = Auth, #{rp_id := RpId} = Expected, Ceremony) ->
    Required = maps:get(user_verification, Expected, preferred) =:= required,
    Checks = [
        {Hash =:= crypto:hash(sha256, RpId), rp_id_mismatch},
        {maps:get(up, Auth), user_not_present},
        {maps:get(uv, Auth) orelse not Required, user_not_verified},
        {maps:get(be, Auth) orelse not maps:get(bs, Auth), invalid_backup_flags},
        {Ceremony =:= authentication orelse maps:is_key(cred_id, Auth), no_credential_data}
    ],
    case [Why || {false, Why} <- Checks] of
        [] -> ok;
        [Why | _] -> {error, Why}
    end.

allowed_alg(Alg, Expected) ->
    case lists:member(Alg, maps:get(algorithms, Expected, livery_auth_cose:algorithms())) of
        true -> ok;
        false -> {error, {algorithm_not_allowed, Alg}}
    end.

%% L3 7.2 step 6: when the user was not identified before the ceremony
%% (a sign-in without a username), the response must name its user, and
%% it must be the credential's.
user_handle(B64, #{user_handle := Handle}, _Expected) when is_binary(B64) ->
    same(b64_decode(B64), {ok, Handle}, user_handle_mismatch);
user_handle(_B64, _Credential, #{user_identified := true}) ->
    ok;
user_handle(null, _Credential, _Expected) ->
    {error, user_handle_missing};
user_handle(_B64, _Credential, _Expected) ->
    {error, user_handle_mismatch}.

stored_signature(CoseBin, Data, Sig) ->
    maybe
        {ok, CoseKey, <<>>} ?= cbor(CoseBin),
        {ok, Alg, Key} ?= livery_auth_cose:public_key(CoseKey),
        signature(Alg, Key, Data, Sig)
    end.

signature(Alg, Key, Data, Sig) ->
    case livery_auth_cose:verify(Alg, Key, Data, Sig) of
        true -> ok;
        false -> {error, bad_signature}
    end.

%% Section 7.2 step 22: a counter that does not move forward means the
%% credential may have been cloned. Synced passkeys always send 0.
counter(0, 0) -> ok;
counter(New, Stored) when New > Stored -> ok;
counter(_New, _Stored) -> {error, cloned_authenticator}.

same(A, A, _What) -> ok;
same(_A, _B, What) -> {error, What}.

field(Name, Resp) ->
    case maps:get(Name, Resp, undefined) of
        B when is_binary(B) ->
            case b64_decode(B) of
                {ok, Bin} -> {ok, Bin};
                error -> {error, {malformed, Name}}
            end;
        _ ->
            {error, {missing, Name}}
    end.

cbor(Bin) ->
    livery_cbor:decode(Bin).

%%====================================================================
%% Authenticator data (section 6.1)
%%====================================================================

auth_data(<<RpIdHash:32/binary, Flags, Count:32, Rest/binary>>) ->
    Base = #{
        rp_id_hash => RpIdHash,
        up => Flags band ?UP =/= 0,
        uv => Flags band ?UV =/= 0,
        be => Flags band ?BE =/= 0,
        bs => Flags band ?BS =/= 0,
        sign_count => Count,
        aaguid => <<0:128>>
    },
    attested(Flags band ?AT =/= 0, Flags band ?ED =/= 0, Rest, Base);
auth_data(_) ->
    {error, malformed_auth_data}.

attested(true, Ed, <<Aaguid:16/binary, Len:16, CredId:Len/binary, KeyAndExt/binary>>, Base) when
    Len =< 1023
->
    case livery_cbor:decode(KeyAndExt) of
        {ok, _Key, Rest} ->
            CoseBin = binary:part(KeyAndExt, 0, byte_size(KeyAndExt) - byte_size(Rest)),
            extensions(Ed, Rest, Base#{aaguid => Aaguid, cred_id => CredId, cose_key => CoseBin});
        {error, _} ->
            {error, malformed_auth_data}
    end;
attested(true, _Ed, _Rest, _Base) ->
    {error, malformed_auth_data};
attested(false, Ed, Rest, Base) ->
    extensions(Ed, Rest, Base).

extensions(false, <<>>, Auth) ->
    {ok, Auth};
extensions(true, Bin, Auth) ->
    case livery_cbor:decode(Bin) of
        {ok, #{} = Ext, <<>>} -> {ok, Auth#{extensions => Ext}};
        _ -> {error, malformed_auth_data}
    end;
extensions(_Ed, _Rest, _Auth) ->
    {error, malformed_auth_data}.

b64(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).

b64_decode(B) when is_binary(B) -> livery_auth_jose:b64url(B);
b64_decode(_) -> error.
