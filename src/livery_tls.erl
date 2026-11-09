-module(livery_tls).
-moduledoc """
The `tls` map adapters put on a request served over TLS.

`livery_req:tls/1` returns `undefined` on a plaintext connection.
Over TLS it returns a map:

- `#{verified => false}` when the client sent no certificate.
- `#{verified => true, cert => Der, subject => Subject, san => San}`
  when it did. TLS only lets a client send a certificate the server
  asked for, and a listener asks only with `verify => verify_peer`,
  which checks the chain against `cacerts` before the handshake ends.
  So a certificate on the request has always been verified.

`subject` lists the subject's attributes in certificate order, as
`{Name, Value}` binaries, for example
`[{<<"O">>, <<"Acme">>}, {<<"CN">>, <<"alice">>}]`. Unknown attributes
are named by their dotted OID. `san` lists the subject alternative
names Livery knows: `{dns, Bin}`, `{email, Bin}`, `{uri, Bin}` and
`{ip, inet:ip_address()}`.
""".

-include_lib("public_key/include/public_key.hrl").

-export([info/1, peer/1]).

-export_type([info/0, san/0]).

-type san() ::
    {dns, binary()}
    | {email, binary()}
    | {uri, binary()}
    | {ip, inet:ip_address()}.

-type info() :: #{
    verified := boolean(),
    cert => binary(),
    subject => [{binary(), binary()}],
    san => [san()]
}.

-doc """
Build the `tls` map from what the wire library's `peercert/1`
returned.
""".
-spec info({ok, binary()} | {error, term()}) -> info().
info({ok, Der}) when is_binary(Der) ->
    Base = #{verified => true, cert => Der},
    try
        #'OTPCertificate'{tbsCertificate = Tbs} = public_key:pkix_decode_cert(Der, otp),
        Base#{
            subject => subject(Tbs#'OTPTBSCertificate'.subject),
            san => san(Tbs#'OTPTBSCertificate'.extensions)
        }
    catch
        _:_ -> Base
    end;
info(_) ->
    #{verified => false}.

-doc """
Call a wire library's `peercert` and build the map. A connection that
is already gone reads as one without a certificate.
""".
-spec peer(fun(() -> {ok, binary()} | {error, term()})) -> info().
peer(PeerCert) ->
    info(
        try
            PeerCert()
        catch
            exit:_ -> {error, closed}
        end
    ).

subject({rdnSequence, Rdns}) ->
    [
        {attr_name(Type), text(Value)}
     || Rdn <- Rdns, #'AttributeTypeAndValue'{type = Type, value = Value} <- Rdn
    ];
subject(_) ->
    [].

attr_name(?'id-at-commonName') ->
    <<"CN">>;
attr_name(?'id-at-organizationName') ->
    <<"O">>;
attr_name(?'id-at-organizationalUnitName') ->
    <<"OU">>;
attr_name(?'id-at-countryName') ->
    <<"C">>;
attr_name(?'id-at-stateOrProvinceName') ->
    <<"ST">>;
attr_name(?'id-at-localityName') ->
    <<"L">>;
attr_name(?'id-at-serialNumber') ->
    <<"serialNumber">>;
attr_name(?'id-emailAddress') ->
    <<"emailAddress">>;
attr_name(?'id-domainComponent') ->
    <<"DC">>;
attr_name(Oid) when is_tuple(Oid) ->
    iolist_to_binary(lists:join(".", [integer_to_list(I) || I <- tuple_to_list(Oid)])).

%% Directory strings decode as `{Tag, Value}'; country and email are
%% plain strings.
text({_Tag, Value}) -> text(Value);
text(Value) when is_binary(Value) -> Value;
text(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
text(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).

san(Extensions) when is_list(Extensions) ->
    case lists:keyfind(?'id-ce-subjectAltName', #'Extension'.extnID, Extensions) of
        #'Extension'{extnValue = Names} when is_list(Names) ->
            [S || Name <- Names, S <- [general_name(Name)], S =/= skip];
        _ ->
            []
    end;
san(_) ->
    [].

general_name({dNSName, V}) -> {dns, text(V)};
general_name({rfc822Name, V}) -> {email, text(V)};
general_name({uniformResourceIdentifier, V}) -> {uri, text(V)};
general_name({iPAddress, <<A, B, C, D>>}) -> {ip, {A, B, C, D}};
general_name({iPAddress, <<_:128>> = Bin}) -> {ip, list_to_tuple([N || <<N:16>> <= Bin])};
general_name({iPAddress, L}) when is_list(L) -> general_name({iPAddress, list_to_binary(L)});
general_name(_) -> skip.
