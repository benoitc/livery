%% @doc A software WebAuthn authenticator for tests.
%%
%% Builds the responses a browser would hand to the server after
%% `navigator.credentials.create/get' and `toJSON()': registration with
%% `none', packed self or packed x5c attestation, and assertions. Every
%% field can be overridden so a test can break exactly one thing.
-module(livery_webauthn_authenticator).

-include_lib("public_key/include/public_key.hrl").

-export([
    new/1,
    register/2,
    assert/3,
    attestation_ca/0,
    leaf/1,
    cbor/1,
    b64/1
]).

-define(RP_ID, <<"example.com">>).
-define(ORIGIN, <<"https://example.com">>).
-define(AAGUID,
    <<16#ad, 16#ce, 0, 16#02, 16#35, 16#bc, 16#c6, 16#0a, 16#64, 16#8b, 16#0b, 16#25, 16#f1, 16#f0,
        16#55, 16#03>>
).

%%====================================================================
%% Keys
%%====================================================================

%% A credential key pair for a COSE algorithm.
new(Alg) ->
    {Priv, Cose} = key(Alg),
    #{alg => Alg, priv => Priv, cose => cbor(Cose), id => crypto:strong_rand_bytes(16), count => 0}.

key(P256) when P256 =:= -7; P256 =:= -9 ->
    ec(secp256r1, 1, 32, P256);
key(P384) when P384 =:= -35; P384 =:= -51 ->
    ec(secp384r1, 2, 48, P384);
key(P521) when P521 =:= -36; P521 =:= -52 ->
    ec(secp521r1, 3, 66, P521);
key(Ed) when Ed =:= -8; Ed =:= -19 ->
    Priv = public_key:generate_key({namedCurve, ed25519}),
    #'ECPrivateKey'{publicKey = X} = Priv,
    {Priv, #{1 => 1, 3 => Ed, -1 => 6, -2 => {bytes, X}}};
key(-53) ->
    Priv = public_key:generate_key({namedCurve, ed448}),
    #'ECPrivateKey'{publicKey = X} = Priv,
    {Priv, #{1 => 1, 3 => -53, -1 => 7, -2 => {bytes, X}}};
key(Rsa) when Rsa =:= -257; Rsa =:= -37 ->
    Priv = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{modulus = N, publicExponent = E} = Priv,
    {Priv, #{
        1 => 3,
        3 => Rsa,
        -1 => {bytes, binary:encode_unsigned(N)},
        -2 => {bytes, binary:encode_unsigned(E)}
    }}.

ec(Curve, Crv, Size, Alg) ->
    Priv = public_key:generate_key({namedCurve, Curve}),
    #'ECPrivateKey'{publicKey = <<4, X:Size/binary, Y:Size/binary>>} = Priv,
    {Priv, #{1 => 2, 3 => Alg, -1 => Crv, -2 => {bytes, X}, -3 => {bytes, Y}}}.

sign(#{alg := Alg, priv := Priv}, Data) ->
    sign(Alg, Priv, Data).

sign(P256, Priv, Data) when P256 =:= -7; P256 =:= -9 ->
    public_key:sign(Data, sha256, Priv);
sign(P384, Priv, Data) when P384 =:= -35; P384 =:= -51 ->
    public_key:sign(Data, sha384, Priv);
sign(P521, Priv, Data) when P521 =:= -36; P521 =:= -52 ->
    public_key:sign(Data, sha512, Priv);
sign(Ed, Priv, Data) when Ed =:= -8; Ed =:= -19; Ed =:= -53 -> public_key:sign(Data, none, Priv);
sign(-257, Priv, Data) ->
    public_key:sign(Data, sha256, Priv);
sign(-37, Priv, Data) ->
    public_key:sign(Data, sha256, Priv, [
        {rsa_padding, rsa_pkcs1_pss_padding}, {rsa_pss_saltlen, 32}, {rsa_mgf1_md, sha256}
    ]).

%%====================================================================
%% Registration
%%====================================================================

%% `Opts': `challenge' (raw, required), `attestation' (`none' default,
%% `self', `x5c', or `{fmt, Name}'), and overrides: `type', `origin',
%% `cross_origin', `top_origin', `bom', `rp_id', `flags', `x5c_leaf',
%% `x5c_alg' ...
register(Cred, Opts) ->
    ClientData = client_data(<<"webauthn.create">>, Opts),
    Flags = maps:get(flags, Opts, 16#45),
    AuthData = <<
        (rp_hash(Opts))/binary,
        Flags,
        (maps:get(count, Cred)):32,
        ?AAGUID/binary,
        (byte_size(maps:get(id, Cred))):16,
        (maps:get(id, Cred))/binary,
        (maps:get(cose, Cred))/binary
    >>,
    Hash = crypto:hash(sha256, ClientData),
    {Fmt, Stmt} = statement(
        maps:get(attestation, Opts, none), Cred, <<AuthData/binary, Hash/binary>>, Opts
    ),
    AttObj = cbor(#{<<"fmt">> => Fmt, <<"attStmt">> => Stmt, <<"authData">> => {bytes, AuthData}}),
    #{
        <<"id">> => b64(maps:get(id, Cred)),
        <<"rawId">> => b64(maps:get(id, Cred)),
        <<"type">> => <<"public-key">>,
        <<"response">> => #{
            <<"clientDataJSON">> => b64(ClientData),
            <<"attestationObject">> => b64(AttObj),
            <<"transports">> => [<<"internal">>]
        }
    }.

statement(none, _Cred, _Data, _Opts) ->
    {<<"none">>, #{}};
statement(self, Cred, Data, _Opts) ->
    {<<"packed">>, #{<<"alg">> => maps:get(alg, Cred), <<"sig">> => {bytes, sign(Cred, Data)}}};
statement(x5c, _Cred, Data, Opts) ->
    {LeafDer, LeafKey, Chain} = maps:get(x5c_leaf, Opts, leaf(#{})),
    Alg = maps:get(x5c_alg, Opts, -7),
    {<<"packed">>, #{
        <<"alg">> => Alg,
        <<"sig">> => {bytes, sign(Alg, LeafKey, Data)},
        <<"x5c">> => [{bytes, D} || D <- [LeafDer | Chain]]
    }};
statement({fmt, Name}, _Cred, _Data, _Opts) ->
    {Name, #{}}.

%%====================================================================
%% Attestation certificates
%%====================================================================

%% A root CA, made once per test run.
attestation_ca() ->
    case persistent_term:get({?MODULE, ca}, undefined) of
        undefined ->
            #{cert := Der, key := Key} = public_key:pkix_test_root_cert("Test Attestation Root", [
                {key, {namedCurve, secp256r1}}, {digest, sha256}
            ]),
            CA = {Der, Key},
            persistent_term:put({?MODULE, ca}, CA),
            CA;
        CA ->
            CA
    end.

%% A leaf issued by the test root. `Overrides': `ou', `ca', `aaguid',
%% `aaguid_critical', `key' (`p256' default, `rsa', `ed25519') and `drop'
%% (subject attributes or `basic_constraints' to leave out).
leaf(Overrides) ->
    {RootDer, RootKey} = attestation_ca(),
    #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{subject = Issuer}} =
        public_key:pkix_decode_cert(RootDer, otp),
    {Priv, Spki} = leaf_key(maps:get(key, Overrides, p256)),
    Drop = maps:get(drop, Overrides, []),
    Subject =
        {rdnSequence, [
            [A]
         || [#'AttributeTypeAndValue'{type = T} = A] <- subject(Overrides),
            not lists:member(T, Drop)
        ]},
    Now = calendar:universal_time(),
    {D, _} = Now,
    Validity = #'Validity'{
        notBefore =
            {utcTime, utc(calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(D) - 1))},
        notAfter =
            {utcTime, utc(calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(D) + 30))}
    },
    Exts = [
        E
     || E <- [
            #'Extension'{
                extnID = ?'id-ce-basicConstraints',
                critical = true,
                extnValue = #'BasicConstraints'{cA = maps:get(ca, Overrides, false)}
            },
            #'Extension'{
                extnID = {1, 3, 6, 1, 4, 1, 45724, 1, 1, 4},
                critical = maps:get(aaguid_critical, Overrides, false),
                extnValue = <<4, 16, (maps:get(aaguid, Overrides, ?AAGUID))/binary>>
            }
        ],
        not lists:member(E#'Extension'.extnID, Drop)
    ],
    Tbs = #'OTPTBSCertificate'{
        version = v3,
        serialNumber = erlang:unique_integer([positive]),
        signature = #'SignatureAlgorithm'{algorithm = ?'ecdsa-with-SHA256'},
        issuer = Issuer,
        validity = Validity,
        subject = Subject,
        subjectPublicKeyInfo = Spki,
        extensions = Exts
    },
    {public_key:pkix_sign(Tbs, RootKey), Priv, []}.

leaf_key(p256) ->
    Priv = public_key:generate_key({namedCurve, secp256r1}),
    #'ECPrivateKey'{publicKey = Point} = Priv,
    {Priv, #'OTPSubjectPublicKeyInfo'{
        algorithm = #'PublicKeyAlgorithm'{
            algorithm = ?'id-ecPublicKey', parameters = {namedCurve, ?'secp256r1'}
        },
        subjectPublicKey = #'ECPoint'{point = Point}
    }};
leaf_key(rsa) ->
    Priv = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{modulus = N, publicExponent = E} = Priv,
    {Priv, #'OTPSubjectPublicKeyInfo'{
        algorithm = #'PublicKeyAlgorithm'{algorithm = ?'rsaEncryption', parameters = 'NULL'},
        subjectPublicKey = #'RSAPublicKey'{modulus = N, publicExponent = E}
    }};
leaf_key(ed25519) ->
    Priv = public_key:generate_key({namedCurve, ed25519}),
    #'ECPrivateKey'{publicKey = X} = Priv,
    {Priv, #'OTPSubjectPublicKeyInfo'{
        algorithm = #'PublicKeyAlgorithm'{algorithm = ?'id-Ed25519', parameters = asn1_NOVALUE},
        subjectPublicKey = #'ECPoint'{point = X}
    }}.

subject(Overrides) ->
    [
        [#'AttributeTypeAndValue'{type = ?'id-at-countryName', value = "SE"}],
        [
            #'AttributeTypeAndValue'{
                type = ?'id-at-organizationName', value = {utf8String, <<"Livery">>}
            }
        ],
        [
            #'AttributeTypeAndValue'{
                type = ?'id-at-organizationalUnitName',
                value = {utf8String, maps:get(ou, Overrides, <<"Authenticator Attestation">>)}
            }
        ],
        [
            #'AttributeTypeAndValue'{
                type = ?'id-at-commonName', value = {utf8String, <<"Test Authenticator">>}
            }
        ]
    ].

utc({Y, M, D}) ->
    lists:flatten(io_lib:format("~2..0B~2..0B~2..0B000000Z", [Y rem 100, M, D])).

%%====================================================================
%% Authentication
%%====================================================================

%% An assertion for `Cred' (with its new `count'); overrides as above plus
%% `user_handle' and `signature'.
assert(Cred, Count, Opts) ->
    ClientData = client_data(<<"webauthn.get">>, Opts),
    AuthData = <<(rp_hash(Opts))/binary, (maps:get(flags, Opts, 16#05)), Count:32>>,
    Sig = maps:get(
        signature, Opts, sign(Cred, <<AuthData/binary, (crypto:hash(sha256, ClientData))/binary>>)
    ),
    Resp0 = #{
        <<"clientDataJSON">> => b64(ClientData),
        <<"authenticatorData">> => b64(AuthData),
        <<"signature">> => b64(Sig)
    },
    Resp =
        case maps:find(user_handle, Opts) of
            {ok, H} -> Resp0#{<<"userHandle">> => b64(H)};
            error -> Resp0
        end,
    #{
        <<"id">> => b64(maps:get(id, Cred)),
        <<"rawId">> => b64(maps:get(id, Cred)),
        <<"type">> => <<"public-key">>,
        <<"response">> => Resp
    }.

%%====================================================================
%% Helpers
%%====================================================================

client_data(Type, Opts) ->
    Base = #{
        <<"type">> => maps:get(type, Opts, Type),
        <<"challenge">> => b64(maps:get(challenge, Opts)),
        <<"origin">> => maps:get(origin, Opts, ?ORIGIN)
    },
    CD = maps:merge(
        Base,
        maps:from_list(
            [{<<"crossOrigin">>, C} || {ok, C} <- [maps:find(cross_origin, Opts)]] ++
                [{<<"topOrigin">>, T} || {ok, T} <- [maps:find(top_origin, Opts)]]
        )
    ),
    Json = iolist_to_binary(json:encode(CD)),
    case maps:get(bom, Opts, false) of
        true -> <<16#EF, 16#BB, 16#BF, Json/binary>>;
        false -> Json
    end.

rp_hash(Opts) -> crypto:hash(sha256, maps:get(rp_id, Opts, ?RP_ID)).

b64(B) -> base64:encode(B, #{mode => urlsafe, padding => false}).

%% Minimal CBOR encoder for the shapes WebAuthn uses.
cbor(N) when is_integer(N), N >= 0 -> head(0, N);
cbor(N) when is_integer(N) -> head(1, -1 - N);
cbor({bytes, B}) ->
    <<(head(2, byte_size(B)))/binary, B/binary>>;
cbor(B) when is_binary(B) -> <<(head(3, byte_size(B)))/binary, B/binary>>;
cbor(L) when is_list(L) -> iolist_to_binary([head(4, length(L)) | [cbor(V) || V <- L]]);
cbor(M) when is_map(M) ->
    iolist_to_binary([
        head(5, map_size(M)) | [[cbor(K), cbor(V)] || {K, V} <- lists:sort(maps:to_list(M))]
    ]);
cbor(false) ->
    <<16#f4>>;
cbor(true) ->
    <<16#f5>>;
cbor(null) ->
    <<16#f6>>.

head(Major, N) when N < 24 -> <<Major:3, N:5>>;
head(Major, N) when N < 16#100 -> <<Major:3, 24:5, N:8>>;
head(Major, N) when N < 16#10000 -> <<Major:3, 25:5, N:16>>;
head(Major, N) when N < 16#100000000 -> <<Major:3, 26:5, N:32>>;
head(Major, N) -> <<Major:3, 27:5, N:64>>.
