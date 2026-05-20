%% @doc Self-signed cert/key loader for H3 tests.
%%
%% Reads the PEM files vendored under `test/certs/' and returns
%% them in the DER shapes the quic library expects (`cert' as
%% raw DER bytes, `key' as a decoded private key term).
-module(livery_test_certs).

-export([load/0, paths/0]).

-spec load() -> {ok, binary(), term()}.
load() ->
    {CertFile, KeyFile} = paths(),
    {ok, CertPem} = file:read_file(CertFile),
    {ok, KeyPem}  = file:read_file(KeyFile),
    [{'Certificate', CertDer, _}] = public_key:pem_decode(CertPem),
    {ok, CertDer, decode_key(KeyPem)}.

-spec paths() -> {file:filename(), file:filename()}.
paths() ->
    Base = code:lib_dir(livery),
    CertFile = filename:join([Base, "..", "..", "..", "..",
                              "test", "certs", "cert.pem"]),
    KeyFile  = filename:join([Base, "..", "..", "..", "..",
                              "test", "certs", "key.pem"]),
    {CertFile, KeyFile}.

decode_key(KeyPem) ->
    case public_key:pem_decode(KeyPem) of
        [{'RSAPrivateKey', Der, not_encrypted}] ->
            public_key:der_decode('RSAPrivateKey', Der);
        [{'ECPrivateKey', Der, not_encrypted}] ->
            public_key:der_decode('ECPrivateKey', Der);
        [{'PrivateKeyInfo', Der, not_encrypted}] ->
            public_key:der_decode('PrivateKeyInfo', Der);
        [{_Type, Der, not_encrypted}] ->
            Der
    end.
