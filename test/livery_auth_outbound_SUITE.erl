%% The auth modules' default outbound calls (JWKS, discovery,
%% introspection) go through livery_client. Over real sockets: they reach
%% a plain HTTP server, and they refuse an HTTPS server whose certificate
%% is not trusted, while the same server answers a client that skips
%% verification.
-module(livery_auth_outbound_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    jwks_fetch_over_http/1,
    jwks_fetch_reports_status/1,
    jwks_fetch_refuses_untrusted_certificate/1,
    introspection_fetch_over_http/1,
    introspection_fetch_refuses_untrusted_certificate/1
]).

-define(JWKS, <<"{\"keys\":[{\"kty\":\"oct\",\"kid\":\"k\"}]}">>).

all() ->
    [
        jwks_fetch_over_http,
        jwks_fetch_reports_status,
        jwks_fetch_refuses_untrusted_certificate,
        introspection_fetch_over_http,
        introspection_fetch_refuses_untrusted_certificate
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {CertFile, KeyFile} = livery_test_certs:paths(),
    {ok, Plain} = livery_h1:start(#{port => 0, stack => [], handler => fun handle/1}),
    {ok, Tls} = livery_h1:start(#{
        port => 0,
        transport => ssl,
        cert => CertFile,
        key => KeyFile,
        stack => [],
        handler => fun handle/1
    }),
    [
        {plain, Plain},
        {tls, Tls},
        {http, base(<<"http://127.0.0.1:">>, h1:server_port(Plain))},
        {https, base(<<"https://localhost:">>, h1:server_port(Tls))}
        | Config
    ].

end_per_suite(Config) ->
    livery_h1:stop(?config(plain, Config)),
    livery_h1:stop(?config(tls, Config)),
    ok.

base(Prefix, Port) ->
    <<Prefix/binary, (integer_to_binary(Port))/binary>>.

%% `/jwks' serves a key set; `/introspect' answers with what it received,
%% so the test sees the request the default fetch sent.
handle(Req) ->
    case livery_req:path(Req) of
        <<"/jwks">> ->
            livery_resp:json(200, ?JWKS);
        <<"/introspect">> ->
            {stream, Reader} = livery_req:body(Req),
            {ok, Body, _} = livery_body:read_all(Reader, 5000),
            Auth = livery_req:header(<<"authorization">>, Req, <<>>),
            livery_resp:json(
                200,
                json:encode(#{<<"active">> => true, <<"body">> => Body, <<"auth">> => Auth})
            );
        _ ->
            livery_resp:text(404, <<"not found">>)
    end.

jwks_fetch_over_http(Config) ->
    Url = <<(?config(http, Config))/binary, "/jwks">>,
    ?assertEqual({ok, ?JWKS}, livery_auth_jwks:default_fetch(Url)).

jwks_fetch_reports_status(Config) ->
    Url = <<(?config(http, Config))/binary, "/missing">>,
    ?assertEqual({error, {http_status, 404}}, livery_auth_jwks:default_fetch(Url)).

jwks_fetch_refuses_untrusted_certificate(Config) ->
    Url = <<(?config(https, Config))/binary, "/jwks">>,
    ?assertMatch({error, _}, livery_auth_jwks:default_fetch(Url)),
    %% The same server answers when verification is skipped, so the
    %% refusal above comes from the certificate check.
    ?assertMatch({ok, 200, _, _}, insecure_get(Url)).

introspection_fetch_over_http(Config) ->
    Url = <<(?config(http, Config))/binary, "/introspect">>,
    Headers = [
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
        {<<"authorization">>, <<"Basic YXBpOnNlYw==">>}
    ],
    {ok, 200, Body} = livery_auth_introspect:default_fetch(Url, Headers, <<"token=abc">>),
    ?assertMatch(
        #{<<"body">> := <<"token=abc">>, <<"auth">> := <<"Basic YXBpOnNlYw==">>},
        json:decode(Body)
    ).

introspection_fetch_refuses_untrusted_certificate(Config) ->
    Url = <<(?config(https, Config))/binary, "/introspect">>,
    ?assertMatch(
        {error, _}, livery_auth_introspect:default_fetch(Url, [], <<"token=abc">>)
    ),
    ?assertMatch({ok, 200, _, _}, insecure_get(<<(?config(https, Config))/binary, "/jwks">>)).

%% Test only: a client that does not verify the server certificate.
insecure_get(Url) ->
    hackney:request(get, Url, [], <<>>, [with_body, {ssl_options, [{verify, verify_none}]}]).
