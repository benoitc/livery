%% @doc WebAuthn Level 3 registration (7.1) and authentication (7.2)
%% checks, driven by a software authenticator.
-module(livery_auth_webauthn_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, livery_webauthn_authenticator).
-define(BASIC_CONSTRAINTS, {2, 5, 29, 19}).
-define(COUNTRY, {2, 5, 4, 6}).
-define(ORG, {2, 5, 4, 10}).
-define(CN, {2, 5, 4, 3}).

x5c_without(Attr, Roots) ->
    #{attestation => x5c, x5c_leaf => ?A:leaf(#{drop => [Attr]}), expect => Roots}.

expected(Challenge) ->
    expected(Challenge, #{}).

expected(Challenge, Extra) ->
    maps:merge(
        #{
            challenge => Challenge,
            rp_id => <<"example.com">>,
            origins => [<<"https://example.com">>]
        },
        Extra
    ).

challenge() -> crypto:strong_rand_bytes(32).

reg(Cred, Opts) ->
    C = challenge(),
    livery_auth_webauthn:verify_registration(
        ?A:register(Cred, Opts#{challenge => C}), expected(C, maps:get(expect, Opts, #{}))
    ).

%%====================================================================
%% Options
%%====================================================================

creation_options_test() ->
    {Challenge, Opts} = livery_auth_webauthn:creation_options(
        #{id => <<"user-1">>, name => <<"alice">>},
        #{rp_id => <<"example.com">>, rp_name => <<"Example">>, exclude => [<<"old">>]}
    ),
    ?assertEqual(32, byte_size(Challenge)),
    ?assertMatch(
        #{
            <<"rp">> := #{<<"id">> := <<"example.com">>, <<"name">> := <<"Example">>},
            <<"user">> := #{<<"name">> := <<"alice">>, <<"displayName">> := <<"alice">>},
            <<"attestation">> := <<"none">>,
            <<"authenticatorSelection">> := #{<<"residentKey">> := <<"preferred">>}
        },
        Opts
    ),
    ?assertEqual(?A:b64(Challenge), maps:get(<<"challenge">>, Opts)),
    ?assertEqual(
        [#{<<"type">> => <<"public-key">>, <<"id">> => ?A:b64(<<"old">>)}],
        maps:get(<<"excludeCredentials">>, Opts)
    ),
    ?assertEqual(json:decode(iolist_to_binary(json:encode(Opts))), Opts).

request_options_discoverable_test() ->
    {_, Opts} = livery_auth_webauthn:request_options(#{rp_id => <<"example.com">>}),
    ?assertEqual([], maps:get(<<"allowCredentials">>, Opts)).

%%====================================================================
%% Registration
%%====================================================================

every_algorithm_registers_test_() ->
    [
        {
            integer_to_list(Alg),
            ?_assertMatch({ok, #{attestation := none}}, reg(?A:new(Alg), #{}))
        }
     || Alg <- livery_auth_cose:algorithms()
    ].

credential_fields_test() ->
    Cred = ?A:new(-7),
    {ok, Stored} = reg(Cred, #{}),
    ?assertMatch(
        #{
            sign_count := 0,
            backup_eligible := false,
            user_verified := true,
            transports := [<<"internal">>]
        },
        Stored
    ),
    ?assertEqual(maps:get(id, Cred), maps:get(id, Stored)),
    ?assertEqual(maps:get(cose, Cred), maps:get(public_key, Stored)).

self_attestation_test() ->
    ?assertMatch({ok, #{attestation := self}}, reg(?A:new(-7), #{attestation => self})).

full_attestation_test() ->
    {Root, _} = ?A:attestation_ca(),
    ?assertMatch(
        {ok, #{attestation := {x5c, _}}},
        reg(?A:new(-7), #{attestation => x5c, expect => #{attestation_roots => [Root]}})
    ).

registration_refusals_test_() ->
    {Root, _} = ?A:attestation_ca(),
    Roots = #{attestation_roots => [Root]},
    OtherDer = maps:get(
        cert,
        public_key:pkix_test_root_cert("Other root", [
            {key, {namedCurve, secp256r1}}, {digest, sha256}
        ])
    ),
    Cases = [
        {"wrong type", #{type => <<"webauthn.get">>}, wrong_type},
        {"wrong origin", #{origin => <<"https://evil.example">>}, origin_mismatch},
        {"cross-origin", #{cross_origin => true}, cross_origin},
        {"wrong RP ID", #{rp_id => <<"evil.example">>}, rp_id_mismatch},
        {"user not present", #{flags => 16#44}, user_not_present},
        {"user not verified, required",
            #{flags => 16#41, expect => #{user_verification => required}}, user_not_verified},
        {"backup state without eligibility", #{flags => 16#55}, invalid_backup_flags},
        {"no credential data", #{flags => 16#05}, malformed_auth_data},
        {"algorithm not allowed", #{expect => #{algorithms => [-8]}}, {algorithm_not_allowed, -7}},
        {"unknown format", #{attestation => {fmt, <<"tpm">>}},
            {unsupported_attestation, <<"tpm">>}},
        {"x5c without roots", #{attestation => x5c}, {invalid_attestation, no_attestation_roots}},
        {"x5c from another root",
            #{attestation => x5c, expect => #{attestation_roots => [OtherDer]}},
            {invalid_attestation, untrusted_chain}},
        {"x5c without the OU",
            #{attestation => x5c, x5c_leaf => ?A:leaf(#{ou => <<"Other">>}), expect => Roots},
            {invalid_attestation, subject_ou}},
        {"x5c leaf is a CA",
            #{attestation => x5c, x5c_leaf => ?A:leaf(#{ca => true}), expect => Roots},
            {invalid_attestation, basic_constraints}},
        {"x5c with another AAGUID",
            #{attestation => x5c, x5c_leaf => ?A:leaf(#{aaguid => <<0:128>>}), expect => Roots},
            {invalid_attestation, aaguid}},
        {"x5c with a critical AAGUID extension",
            #{attestation => x5c, x5c_leaf => ?A:leaf(#{aaguid_critical => true}), expect => Roots},
            {invalid_attestation, aaguid}},
        {"x5c without basic constraints",
            #{
                attestation => x5c,
                x5c_leaf => ?A:leaf(#{drop => [?BASIC_CONSTRAINTS]}),
                expect => Roots
            },
            {invalid_attestation, basic_constraints}},
        {"x5c without a country", x5c_without(?COUNTRY, Roots), {invalid_attestation, subject_c}},
        {"x5c without an organization", x5c_without(?ORG, Roots), {invalid_attestation, subject_o}},
        {"x5c without a common name", x5c_without(?CN, Roots), {invalid_attestation, subject_cn}},
        {"x5c alg that does not fit the key",
            #{attestation => x5c, x5c_alg => -35, expect => Roots}, {invalid_attestation, alg}},
        {"none with roots", #{expect => Roots}, {untrusted_attestation, none}},
        {"self with roots", #{attestation => self, expect => Roots}, {untrusted_attestation, self}},
        {"top origin, cross-origin not allowed", #{top_origin => <<"https://shop.example">>},
            top_origin_mismatch}
    ],
    [{Name, ?_assertEqual({error, Why}, reg(?A:new(-7), Opts))} || {Name, Opts, Why} <- Cases].

full_attestation_key_types_test_() ->
    {Root, _} = ?A:attestation_ca(),
    [
        {atom_to_list(Key), fun() ->
            ?assertMatch(
                {ok, #{attestation := {x5c, _}}},
                reg(?A:new(-7), #{
                    attestation => x5c,
                    x5c_leaf => ?A:leaf(#{key => Key}),
                    x5c_alg => Alg,
                    expect => #{attestation_roots => [Root]}
                })
            )
        end}
     || {Key, Alg} <- [{p256, -9}, {rsa, -257}, {rsa, -37}, {ed25519, -8}]
    ].

unattested_with_roots_when_allowed_test() ->
    {Root, _} = ?A:attestation_ca(),
    ?assertMatch(
        {ok, #{attestation := none}},
        reg(?A:new(-7), #{expect => #{attestation_roots => [Root], allow_unattested => true}})
    ).

client_data_with_bom_test() ->
    ?assertMatch({ok, _}, reg(?A:new(-7), #{bom => true})).

framed_by_an_expected_page_test() ->
    ?assertMatch(
        {ok, _},
        reg(?A:new(-7), #{
            cross_origin => true,
            top_origin => <<"https://shop.example">>,
            expect => #{allow_cross_origin => true, top_origins => [<<"https://shop.example">>]}
        })
    ).

eddsa_is_ed25519_only_test() ->
    #{cose := Cose} = ?A:new(-53),
    {ok, Key, <<>>} = livery_cbor:decode(Cose),
    ?assertEqual({error, {unsupported_key, -8, 7}}, livery_auth_cose:public_key(Key#{3 => -8})).

wrong_challenge_test() ->
    Cred = ?A:new(-7),
    Resp = ?A:register(Cred, #{challenge => challenge()}),
    ?assertEqual(
        {error, challenge_mismatch},
        livery_auth_webauthn:verify_registration(Resp, expected(challenge()))
    ).

unknown_format_allowed_when_asked_test() ->
    ?assertMatch(
        {ok, #{attestation := unattested}},
        reg(?A:new(-7), #{
            attestation => {fmt, <<"tpm">>}, expect => #{allow_unattested => true}
        })
    ).

bad_self_signature_test() ->
    Cred = ?A:new(-7),
    Other = ?A:new(-7),
    %% Sign with another key but present this credential's public key.
    ?assertEqual(
        {error, {invalid_attestation, signature}},
        reg(Cred#{priv => maps:get(priv, Other)}, #{attestation => self})
    ).

%%====================================================================
%% Authentication
%%====================================================================

stored(Cred, Extra) ->
    {ok, S} = reg(Cred, #{}),
    maps:merge(S#{user_handle => <<"user-1">>}, Extra).

%% Sends the stored user handle unless the case says otherwise
%% (`user_handle => none' sends none).
authenticate(Cred, Stored, Count, Opts0) ->
    C = challenge(),
    Opts =
        case maps:get(user_handle, Opts0, <<"user-1">>) of
            none -> maps:remove(user_handle, Opts0);
            H -> Opts0#{user_handle => H}
        end,
    livery_auth_webauthn:verify_authentication(
        ?A:assert(Cred, Count, Opts#{challenge => C}),
        Stored,
        expected(C, maps:get(expect, Opts, #{}))
    ).

authentication_test_() ->
    [
        {integer_to_list(Alg), fun() ->
            Cred = ?A:new(Alg),
            ?assertMatch({ok, #{sign_count := 1}}, authenticate(Cred, stored(Cred, #{}), 1, #{}))
        end}
     || Alg <- livery_auth_cose:algorithms()
    ].

synced_passkey_counter_zero_test() ->
    Cred = ?A:new(-7),
    ?assertMatch({ok, #{sign_count := 0}}, authenticate(Cred, stored(Cred, #{}), 0, #{})).

authentication_refusals_test_() ->
    Cred = ?A:new(-7),
    Stored = stored(Cred, #{sign_count => 5}),
    Other = ?A:new(-7),
    Cases = [
        {"counter went back", Stored, 5, #{}, cloned_authenticator},
        {"wrong type", Stored, 6, #{type => <<"webauthn.create">>}, wrong_type},
        {"wrong origin", Stored, 6, #{origin => <<"https://evil.example">>}, origin_mismatch},
        {"wrong RP ID", Stored, 6, #{rp_id => <<"evil.example">>}, rp_id_mismatch},
        {"user not present", Stored, 6, #{flags => 16#04}, user_not_present},
        {"user not verified, required", Stored, 6,
            #{flags => 16#01, expect => #{user_verification => required}}, user_not_verified},
        {"backup eligibility changed", Stored, 6, #{flags => 16#0d}, backup_eligible},
        {"another user", Stored, 6, #{user_handle => <<"user-2">>}, user_handle_mismatch},
        {"no user handle, user not identified", Stored, 6, #{user_handle => none},
            user_handle_missing},
        {"framed by an unexpected page", Stored, 6,
            #{
                cross_origin => true,
                top_origin => <<"https://evil.example">>,
                expect => #{allow_cross_origin => true, top_origins => [<<"https://shop.example">>]}
            },
            top_origin_mismatch},
        {"top origin without cross-origin allowed", Stored, 6,
            #{top_origin => <<"https://shop.example">>}, top_origin_mismatch},
        {"signed by another key", Stored, 6, #{signature => crypto:strong_rand_bytes(70)},
            bad_signature}
    ],
    _ = Other,
    [
        {Name, ?_assertEqual({error, Why}, authenticate(Cred, S, Count, Opts))}
     || {Name, S, Count, Opts, Why} <- Cases
    ].

other_credential_test() ->
    Cred = ?A:new(-7),
    Other = ?A:new(-7),
    ?assertEqual({error, credential_id}, authenticate(Other, stored(Cred, #{}), 1, #{})).

%%====================================================================
%% Recorded browser responses
%%
%% From the test suite of py_webauthn (Duo Labs, BSD 3-Clause), which
%% recorded them from real authenticators: a check against data no part
%% of Livery produced.
%%====================================================================

b64d(B) ->
    {ok, Bin} = livery_auth_jose:b64url(B),
    Bin.

%% These sign-ins named their credential (no user handle in the
%% response), so the user was identified before the ceremony.
localhost(Challenge) ->
    #{
        challenge => b64d(Challenge),
        rp_id => <<"localhost">>,
        origins => [<<"http://localhost:5000">>],
        user_identified => true
    }.

recorded_none_registration_test() ->
    Resp = #{
        <<"id">> =>
            <<"9y1xA8Tmg1FEmT-c7_fvWZ_uoTuoih3OvR45_oAK-cwHWhAbXrl2q62iLVTjiyEZ7O7n-CROOY494k7Q3xrs_w">>,
        <<"rawId">> =>
            <<"9y1xA8Tmg1FEmT-c7_fvWZ_uoTuoih3OvR45_oAK-cwHWhAbXrl2q62iLVTjiyEZ7O7n-CROOY494k7Q3xrs_w">>,
        <<"type">> => <<"public-key">>,
        <<"response">> => #{
            <<"attestationObject">> =>
                <<"o2NmbXRkbm9uZWdhdHRTdG10oGhhdXRoRGF0YVjESZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2NFAAAAFwAAAAAAAAAAAAAAAAAAAAAAQPctcQPE5oNRRJk_nO_371mf7qE7qIodzr0eOf6ACvnMB1oQG165dqutoi1U44shGezu5_gkTjmOPeJO0N8a7P-lAQIDJiABIVggSFbUJF-42Ug3pdM8rDRFu_N5oiVEysPDB6n66r_7dZAiWCDUVnB39FlGypL-qAoIO9xWHtJygo2jfDmHl-_eKFRLDA">>,
            <<"clientDataJSON">> =>
                <<"eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIiwiY2hhbGxlbmdlIjoiVHdON240V1R5R0tMYzRaWS1xR3NGcUtuSE00bmdscXN5VjBJQ0psTjJUTzlYaVJ5RnRya2FEd1V2c3FsLWdrTEpYUDZmbkYxTWxyWjUzTW00UjdDdnciLCJvcmlnaW4iOiJodHRwOi8vbG9jYWxob3N0OjUwMDAiLCJjcm9zc09yaWdpbiI6ZmFsc2V9">>
        }
    },
    Expected = localhost(
        <<"TwN7n4WTyGKLc4ZY-qGsFqKnHM4nglqsyV0ICJlN2TO9XiRyFtrkaDwUvsql-gkLJXP6fnF1MlrZ53Mm4R7Cvw">>
    ),
    {ok, Cred} = livery_auth_webauthn:verify_registration(Resp, Expected),
    ?assertMatch(#{attestation := none, sign_count := 23, aaguid := <<0:128>>}, Cred),
    ?assertEqual(b64d(maps:get(<<"rawId">>, Resp)), maps:get(id, Cred)).

recorded_ec2_authentication_test() ->
    Id =
        <<"EDx9FfAbp4obx6oll2oC4-CZuDidRVV4gZhxC529ytlnqHyqCStDUwfNdm1SNHAe3X5KvueWQdAX3x9R1a2b9Q">>,
    Resp = #{
        <<"id">> => Id,
        <<"rawId">> => Id,
        <<"type">> => <<"public-key">>,
        <<"response">> => #{
            <<"authenticatorData">> => <<"SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2MBAAAATg">>,
            <<"clientDataJSON">> =>
                <<"eyJjaGFsbGVuZ2UiOiJ4aTMwR1BHQUZZUnhWRHBZMXNNMTBEYUx6VlFHNjZudi1fN1JVYXpIMHZJMll2RzhMWWdERW52TjVmWlpOVnV2RUR1TWk5dGUzVkxxYjQyTjBma0xHQSIsImNsaWVudEV4dGVuc2lvbnMiOnt9LCJoYXNoQWxnb3JpdGhtIjoiU0hBLTI1NiIsIm9yaWdpbiI6Imh0dHA6Ly9sb2NhbGhvc3Q6NTAwMCIsInR5cGUiOiJ3ZWJhdXRobi5nZXQifQ">>,
            <<"signature">> =>
                <<"MEUCIGisVZOBapCWbnJJvjelIzwpixxIwkjCCb5aCHafQu68AiEA88v-2pJNNApPFwAKFiNuf82-2hBxYW5kGwVweeoxCwo">>
        }
    },
    Stored = #{
        id => b64d(Id),
        public_key => b64d(
            <<"pQECAyYgASFYIIeDTe-gN8A-zQclHoRnGFWN8ehM1b7yAsa8I8KIvmplIlgg4nFGT5px8o6gpPZZhO01wdy9crDSA_Ngtkx0vGpvPHI">>
        ),
        sign_count => 77,
        backup_eligible => false
    },
    Expected = localhost(
        <<"xi30GPGAFYRxVDpY1sM10DaLzVQG66nv-_7RUazH0vI2YvG8LYgDEnvN5fZZNVuvEDuMi9te3VLqb42N0fkLGA">>
    ),
    ?assertEqual(
        {ok, #{sign_count => 78, backup_state => false, user_verified => false}},
        livery_auth_webauthn:verify_authentication(Resp, Stored, Expected)
    ),
    ?assertEqual(
        {error, cloned_authenticator},
        livery_auth_webauthn:verify_authentication(Resp, Stored#{sign_count => 78}, Expected)
    ).

recorded_okp_authentication_test() ->
    Id =
        <<"fq9Nj0nS24B5y6Pkw_h3-9GEAEA3-0LBPxE2zvTdLjDqtSeCSNYFe9VMRueSpAZxT3YDc6L1lWXdQNwI-sVNYrefEcRR1Nsb_0jpHE955WEtFud2xxZg3MvoLMxHLet63i5tajd1fHtP7I-00D6cehM8ZWlLp2T3s9lfZgVIFcA">>,
    Resp = #{
        <<"id">> => Id,
        <<"rawId">> => Id,
        <<"type">> => <<"public-key">>,
        <<"response">> => #{
            <<"authenticatorData">> => <<"SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2MBAAAABw">>,
            <<"clientDataJSON">> =>
                <<"eyJ0eXBlIjoid2ViYXV0aG4uZ2V0IiwiY2hhbGxlbmdlIjoiZVo0ZWVBM080ank1Rkl6cURhU0o2SkROR3UwYkJjNXpJMURqUV9rTHNvMVdOcWtHNms1bUNZZjFkdFFoVlVpQldaV2xaa3pSNU1GZWVXQ3BKUlVOWHciLCJvcmlnaW4iOiJodHRwOi8vbG9jYWxob3N0OjUwMDAiLCJjcm9zc09yaWdpbiI6ZmFsc2V9">>,
            <<"signature">> =>
                <<"RRWV8mYDRvK7YdQgdtZD4pJ2dh1D_IWZ_D6jsZo6FHJBoenbj0CVT5nA20vUzlRhN4R6dOEUHmUwP1F8eRBhBg">>
        }
    },
    Stored = #{
        id => b64d(Id),
        public_key => b64d(<<"pAEBAycgBiFYIMz6_SUFLiDid2Yhlq0YboyJ-CDrIrNpkPUGmJp4D3Dp">>),
        sign_count => 3,
        backup_eligible => false
    },
    Expected = localhost(
        <<"eZ4eeA3O4jy5FIzqDaSJ6JDNGu0bBc5zI1DjQ_kLso1WNqkG6k5mCYf1dtQhVUiBWZWlZkzR5MFeeWCpJRUNXw">>
    ),
    ?assertMatch(
        {ok, #{sign_count := 7}}, livery_auth_webauthn:verify_authentication(Resp, Stored, Expected)
    ).

%%====================================================================
%% Recorded YubiKey registrations
%%
%% Packed attestation from real YubiKeys (an ES256 and an EdDSA
%% credential), from the py_webauthn test suite, checked against
%% Yubico's published root, "Yubico U2F Root CA Serial 457200631"
%% (https://developers.yubico.com/U2F/yubico-u2f-ca-certs.txt).
%%====================================================================

yubico_root() ->
    base64:decode(
        <<"MIIDHjCCAgagAwIBAgIEG0BT9zANBgkqhkiG9w0BAQsFADAuMSwwKgYDVQQDEyNZdWJpY28gVTJGIFJvb3QgQ0EgU2VyaWFsIDQ1NzIwMDYzMTAgFw0xNDA4MDEwMDAwMDBaGA8yMDUwMDkwNDAwMDAwMFowLjEsMCoGA1UEAxMjWXViaWNvIFUyRiBSb290IENBIFNlcmlhbCA0NTcyMDA2MzEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC/jwYuhBVlqaiYWEMsrWFisgJ+PtM91eSrpI4TK7U53mwCIawSDHy8vUmk5N2KAj9abvT9NP5SMS1hQi3usxoYGonXQgfO6ZXyUA9a+KAkqdFnBnlyugSeCOep8EdZFfsaRFtMjkwz5Gcz2Py4vIYvCdMHPtwaz0bVuzneueIEz6TnQjE63Rdt2zbwnebwTG5ZybeWSwbzy+BJ34ZHcUhPAY89yJQXuE0IzMZFcEBbPNRbWECRKgjq//qT9nmDOFVlSRCt2wiqPSzluwn+v+suQEBsUjTGMEd25tKXXTkNW21wIWbxeSyUoTXwLvGS6xlwQSgNpk2qXYwf8iXg7VWZAgMBAAGjQjBAMB0GA1UdDgQWBBQgIvz0bNGJhjgpToksyKpP9xv9oDAPBgNVHRMECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEAjvjuOMDSa+JXFCLyBKsycXtBVZsJ4Ue3LbaEsPY4MYN/hIQ5ZM5p7EjfcnMG4CtYkNsfNHc0AhBLdq45rnT87q/6O3vUEtNMafbhU6kthX7Y+9XFN9NpmYxr+ekVY5xOxi8h9JDIgoMP4VB1uS0aunL1IGqrNooL9mmFnL2kLVVee6/VR6C5+KSTCMCWppMuJIZII2v9o4dkoZ8Y7QRjQlLfYzd3qGtKbw7xaF1UsG/5xUb/Btwb2X2g4InpiB/yt/3CpQXpiWX/K4mBvUKiGn05ZsqeY1gx4g0xLBqcU9psmyPzK+Vsgw2jeRQ5JlKDyqE0hebfC1tvFu0CCrJFcw==">>
    ).

yubikey_es256() ->
    #{
        <<"id">> =>
            <<"syGQPDZRUYdb4m3rdWeyPaIMYlbmydGp1TP_33vE_lqJ3PHNyTd0iKsnKr5WjnCcBzcesZrDEfB_RBLFzU3k4w">>,
        <<"rawId">> =>
            <<"syGQPDZRUYdb4m3rdWeyPaIMYlbmydGp1TP_33vE_lqJ3PHNyTd0iKsnKr5WjnCcBzcesZrDEfB_RBLFzU3k4w">>,
        <<"type">> => <<"public-key">>,
        <<"response">> => #{
            <<"attestationObject">> =>
                <<"o2NmbXRmcGFja2VkZ2F0dFN0bXSjY2FsZyZjc2lnWEcwRQIhAOfrFlQpbavT6dJeTDJSCDzYSYPjBDHli2-syT2c1IiKAiAx5gQ2z5cHjdQX-jEHTb7JcjfQoVSW8fXszF5ihSgeOGN4NWOBWQLBMIICvTCCAaWgAwIBAgIEKudiYzANBgkqhkiG9w0BAQsFADAuMSwwKgYDVQQDEyNZdWJpY28gVTJGIFJvb3QgQ0EgU2VyaWFsIDQ1NzIwMDYzMTAgFw0xNDA4MDEwMDAwMDBaGA8yMDUwMDkwNDAwMDAwMFowbjELMAkGA1UEBhMCU0UxEjAQBgNVBAoMCVl1YmljbyBBQjEiMCAGA1UECwwZQXV0aGVudGljYXRvciBBdHRlc3RhdGlvbjEnMCUGA1UEAwweWXViaWNvIFUyRiBFRSBTZXJpYWwgNzE5ODA3MDc1MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEKgOGXmBD2Z4R_xCqJVRXhL8Jr45rHjsyFykhb1USGozZENOZ3cdovf5Ke8fj2rxi5tJGn_VnW4_6iQzKdIaeP6NsMGowIgYJKwYBBAGCxAoCBBUxLjMuNi4xLjQuMS40MTQ4Mi4xLjEwEwYLKwYBBAGC5RwCAQEEBAMCBDAwIQYLKwYBBAGC5RwBAQQEEgQQbUS6m_bsLkm5MAyP6SDLczAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IBAQByV9A83MPhFWmEkNb4DvlbUwcjc9nmRzJjKxHc3HeK7GvVkm0H4XucVDB4jeMvTke0WHb_jFUiApvpOHh5VyMx5ydwFoKKcRs5x0_WwSWL0eTZ5WbVcHkDR9pSNcA_D_5AsUKOBcbpF5nkdVRxaQHuuIuwV4k1iK2IqtMNcU8vL6w21U261xCcWwJ6sMq4zzVO8QCKCQhsoIaWrwz828GDmPzfAjFsJiLJXuYivdHACkeJ5KHMt0mjVLpfJ2BCML7_rgbmvwL7wBW80VHfNdcKmKjkLcpEiPzwcQQhiN_qHV90t-p4iyr5xRSpurlP5zic2hlRkLKxMH2_kRjhqSn4aGF1dGhEYXRhWMRJlg3liA6MaHQ0Fw9kdmBbj-SuuaKGMseZXPO6gx2XY0UAAAA0bUS6m_bsLkm5MAyP6SDLcwBAsyGQPDZRUYdb4m3rdWeyPaIMYlbmydGp1TP_33vE_lqJ3PHNyTd0iKsnKr5WjnCcBzcesZrDEfB_RBLFzU3k46UBAgMmIAEhWCBAX_i3O3DvBnkGq_uLNk_PeAX5WwO_MIxBp0mhX6Lw7yJYIOW-1-Fch829McWvRUYAHTWZTx5IycKSGECL1UzUaK_8">>,
            <<"clientDataJSON">> =>
                <<"eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIiwiY2hhbGxlbmdlIjoiOExCQ2lPWTNxMWNCWkhGQVd0UzRBWlpDaHpHcGh5NjdsSzdJNzB6S2k0eUM3cGdyUTJQY2g3bkFqTGsxd3E5Z3Jlc2hJQXNXMkFqaWJoWGpqSTBUbVEiLCJvcmlnaW4iOiJodHRwOi8vbG9jYWxob3N0OjUwMDAiLCJjcm9zc09yaWdpbiI6ZmFsc2V9">>
        }
    }.

yubikey_es256_challenge() ->
    <<"8LBCiOY3q1cBZHFAWtS4AZZChzGphy67lK7I70zKi4yC7pgrQ2Pch7nAjLk1wq9greshIAsW2AjibhXjjI0TmQ">>.

yubikey_eddsa() ->
    #{
        <<"id">> =>
            <<"WlHiMqH6UhUs-d43z-aGlE3nsXuEOQpa9P9pwpqb4tmvtBMBfGvAV2wUrqBCDENjkkxd6kIRzZQKcluyOFlyW_vXVZSAEgod1xj-1QmFpuwyBVnlkQGefRbmUjbEt5iE4q3tdjy65EWIekO0SNjCQx3LxIJMzi25fgUkI9Y-gg0">>,
        <<"rawId">> =>
            <<"WlHiMqH6UhUs-d43z-aGlE3nsXuEOQpa9P9pwpqb4tmvtBMBfGvAV2wUrqBCDENjkkxd6kIRzZQKcluyOFlyW_vXVZSAEgod1xj-1QmFpuwyBVnlkQGefRbmUjbEt5iE4q3tdjy65EWIekO0SNjCQx3LxIJMzi25fgUkI9Y-gg0">>,
        <<"type">> => <<"public-key">>,
        <<"response">> => #{
            <<"attestationObject">> =>
                <<"o2NmbXRmcGFja2VkZ2F0dFN0bXSjY2FsZyZjc2lnWEcwRQIgB3c0BvOsyJut14wj4XVWxXliicWZMZLDNF621Zz7h_8CIQCIOqRyWOazVhqlBrD-HL-83KWAvGZRgvW-4A9SE8BLFWN4NWOBWQLBMIICvTCCAaWgAwIBAgIEK_F8eDANBgkqhkiG9w0BAQsFADAuMSwwKgYDVQQDEyNZdWJpY28gVTJGIFJvb3QgQ0EgU2VyaWFsIDQ1NzIwMDYzMTAgFw0xNDA4MDEwMDAwMDBaGA8yMDUwMDkwNDAwMDAwMFowbjELMAkGA1UEBhMCU0UxEjAQBgNVBAoMCVl1YmljbyBBQjEiMCAGA1UECwwZQXV0aGVudGljYXRvciBBdHRlc3RhdGlvbjEnMCUGA1UEAwweWXViaWNvIFUyRiBFRSBTZXJpYWwgNzM3MjQ2MzI4MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEdMLHhCPIcS6bSPJZWGb8cECuTN8H13fVha8Ek5nt-pI8vrSflxb59Vp4bDQlH8jzXj3oW1ZwUDjHC6EnGWB5i6NsMGowIgYJKwYBBAGCxAoCBBUxLjMuNi4xLjQuMS40MTQ4Mi4xLjcwEwYLKwYBBAGC5RwCAQEEBAMCAiQwIQYLKwYBBAGC5RwBAQQEEgQQxe9V_62aS5-1gK3rr-Am0DAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IBAQCLbpN2nXhNbunZANJxAn_Cd-S4JuZsObnUiLnLLS0FPWa01TY8F7oJ8bE-aFa4kTe6NQQfi8-yiZrQ8N-JL4f7gNdQPSrH-r3iFd4SvroDe1jaJO4J9LeiFjmRdcVa-5cqNF4G1fPCofvw9W4lKnObuPakr0x_icdVq1MXhYdUtQk6Zr5mBnc4FhN9qi7DXqLHD5G7ZFUmGwfIcD2-0m1f1mwQS8yRD5-_aDCf3vutwddoi3crtivzyromwbKklR4qHunJ75LGZLZA8pJ_mXnUQ6TTsgRqPvPXgQPbSyGMf2z_DIPbQqCD_Bmc4dj9o6LozheBdDtcZCAjSPTAd_uiaGF1dGhEYXRhWOFJlg3liA6MaHQ0Fw9kdmBbj-SuuaKGMseZXPO6gx2XY0EAAAACxe9V_62aS5-1gK3rr-Am0ACAWlHiMqH6UhUs-d43z-aGlE3nsXuEOQpa9P9pwpqb4tmvtBMBfGvAV2wUrqBCDENjkkxd6kIRzZQKcluyOFlyW_vXVZSAEgod1xj-1QmFpuwyBVnlkQGefRbmUjbEt5iE4q3tdjy65EWIekO0SNjCQx3LxIJMzi25fgUkI9Y-gg2kAQEDJyAGIVggnB_oUZDQU0esRlNPmjEO96aMDTgs34D8Dv31tAwhUZo">>,
            <<"clientDataJSON">> =>
                <<"eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIiwiY2hhbGxlbmdlIjoiN0pVQmpXWkZkRm96dWx4YjcxRHZIa2gzUDZXS1VHNEVsVW83d0VrS2ljMkpFVEpNQUlLQ2Y3ckJFOVlrc0k1b05qRHpRNkhxaDZFNzNPeTZTUGNNbnciLCJvcmlnaW4iOiJodHRwOi8vbG9jYWxob3N0OjUwMDAiLCJjcm9zc09yaWdpbiI6ZmFsc2V9">>
        }
    }.

yubikey_eddsa_challenge() ->
    <<"7JUBjWZFdFozulxb71DvHkh3P6WKUG4ElUo7wEkKic2JETJMAIKCf7rBE9YksI5oNjDzQ6Hqh6E73Oy6SPcMnw">>.

yubikey_test_() ->
    [
        {Name, fun() ->
            Expected = (localhost(Challenge()))#{attestation_roots => [yubico_root()]},
            {ok, Cred} = livery_auth_webauthn:verify_registration(Resp(), Expected),
            ?assertMatch(#{attestation := {x5c, _}}, Cred),
            ?assertEqual(b64d(maps:get(<<"rawId">>, Resp())), maps:get(id, Cred))
        end}
     || {Name, Resp, Challenge} <- [
            {"YubiKey, ES256", fun yubikey_es256/0, fun yubikey_es256_challenge/0},
            {"YubiKey, EdDSA", fun yubikey_eddsa/0, fun yubikey_eddsa_challenge/0}
        ]
    ].

%% The same YubiKey is refused when only another vendor's root is trusted.
yubikey_other_root_test() ->
    {Other, _} = ?A:attestation_ca(),
    Expected = (localhost(yubikey_es256_challenge()))#{attestation_roots => [Other]},
    ?assertEqual(
        {error, {invalid_attestation, untrusted_chain}},
        livery_auth_webauthn:verify_registration(yubikey_es256(), Expected)
    ).
