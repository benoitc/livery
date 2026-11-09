%% @doc Mutual TLS over every TLS listener: H1, H2, the H1/H2 ALPN
%% listener, and H3.
%%
%% A listener started with `verify => verify_peer' and `cacerts' refuses
%% a client without a certificate and puts a verified one on the request
%% (`livery_req:tls/1'). A TLS listener that does not ask for one reports
%% `#{verified => false}'.
-module(livery_mtls_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    client_cert_on_request/1,
    certless_client_refused/1,
    no_client_auth/1
]).

-define(CASES, [client_cert_on_request, certless_client_refused, no_client_auth]).

all() ->
    [{group, h1}, {group, h2}, {group, h1h2}, {group, h3}].

groups() ->
    [{G, [], ?CASES} || G <- [h1, h2, h1h2, h3]].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(quic),
    #{server_config := Server, client_config := Client} = public_key:pkix_test_data(#{
        server_chain => chain([{dNSName, "localhost"}]),
        client_chain => chain([
            {dNSName, "alice.example"},
            {uniformResourceIdentifier, "spiffe://acme/alice"}
        ])
    }),
    Dir = ?config(priv_dir, Config),
    CertFile = filename:join(Dir, "server.pem"),
    KeyFile = filename:join(Dir, "server-key.pem"),
    {KeyType, KeyDer} = proplists:get_value(key, Server),
    ServerCert = proplists:get_value(cert, Server),
    ok = file:write_file(
        CertFile, public_key:pem_encode([{'Certificate', ServerCert, not_encrypted}])
    ),
    ok = file:write_file(KeyFile, public_key:pem_encode([{KeyType, KeyDer, not_encrypted}])),
    [
        {server, #{
            cert_file => CertFile,
            key_file => KeyFile,
            cert => ServerCert,
            key => public_key:der_decode(KeyType, KeyDer),
            %% The client chain's root, the anchors client certificates are
            %% checked against.
            cacerts => proplists:get_value(cacerts, Server)
        }},
        {client, Client}
        | Config
    ].

end_per_suite(_Config) ->
    ok.

init_per_group(Group, Config) ->
    [{proto, Group} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TC, Config) ->
    Auth =
        case TC of
            no_client_auth -> #{};
            _ -> #{verify => verify_peer, cacerts => maps:get(cacerts, ?config(server, Config))}
        end,
    {Mod, Ref, Port} = start(?config(proto, Config), ?config(server, Config), Auth),
    [{listener, {Mod, Ref}}, {port, Port} | Config].

end_per_testcase(_TC, Config) ->
    {Mod, Ref} = ?config(listener, Config),
    Mod:stop(Ref),
    ok.

%%====================================================================
%% Cases
%%====================================================================

client_cert_on_request(Config) ->
    ClientCert = proplists:get_value(cert, ?config(client, Config)),
    {ok, Tls} = fetch(Config, with_cert),
    ?assertMatch(#{verified := true, cert := ClientCert}, Tls),
    ?assert(lists:member({<<"CN">>, <<"client Peer cert">>}, maps:get(subject, Tls))),
    ?assertEqual(
        [{dns, <<"alice.example">>}, {uri, <<"spiffe://acme/alice">>}],
        maps:get(san, Tls)
    ).

certless_client_refused(Config) ->
    ?assertMatch({error, _}, fetch(Config, without_cert)).

no_client_auth(Config) ->
    ?assertEqual({ok, #{verified => false}}, fetch(Config, without_cert)).

%%====================================================================
%% Listeners
%%====================================================================

%% The handler sends back what the request says about the TLS peer.
handler() ->
    fun(Req) ->
        livery_resp:text(200, term_to_binary(livery_req:tls(Req)))
    end.

start(h3, Server, Auth) ->
    Opts = maps:merge(Auth, #{
        port => 0,
        cert => maps:get(cert, Server),
        key => maps:get(key, Server),
        stack => [],
        handler => handler()
    }),
    {ok, Name} = livery_h3:start(Opts),
    {ok, Port} = quic:get_server_port(Name),
    {livery_h3, Name, Port};
start(Proto, Server, Auth) ->
    Opts = maps:merge(Auth, #{
        port => 0,
        transport => ssl,
        cert => maps:get(cert_file, Server),
        key => maps:get(key_file, Server),
        stack => [],
        handler => handler()
    }),
    case Proto of
        h1 ->
            {ok, Ref} = livery_h1:start(Opts),
            {livery_h1, Ref, h1:server_port(Ref)};
        h2 ->
            {ok, Ref} = livery_h2:start(Opts),
            {livery_h2, Ref, h2:server_port(Ref)};
        h1h2 ->
            {ok, Ref} = livery_h1h2:start(Opts#{alpn => [h2, http1]}),
            {livery_h1h2, Ref, livery_h1h2:server_port(Ref)}
    end.

%%====================================================================
%% Clients
%%====================================================================

%% `{ok, TlsMap}' when the request went through, `{error, _}' when the
%% server refused the client during or right after the handshake (with
%% TLS 1.3 the client may finish its handshake before the server's alert
%% arrives, so the refusal can show up on the first read).
fetch(Config, Which) ->
    Port = ?config(port, Config),
    ClientOpts =
        case Which of
            with_cert -> ?config(client, Config);
            without_cert -> []
        end,
    case ?config(proto, Config) of
        h1 -> fetch_h1(Port, ClientOpts);
        h2 -> fetch_h2(Port, ClientOpts);
        h1h2 -> fetch_h1(Port, ClientOpts);
        h3 -> fetch_h3(Port, ClientOpts)
    end.

ssl_client_opts(ClientOpts) ->
    [{verify, verify_none}, {server_name_indication, "localhost"}] ++
        [{K, V} || {K, V} <- ClientOpts, K =:= cert orelse K =:= key].

fetch_h1(Port, ClientOpts) ->
    SslOpts = [binary, {active, false} | ssl_client_opts(ClientOpts)],
    case ssl:connect("127.0.0.1", Port, SslOpts, 5000) of
        {ok, Socket} ->
            try
                _ = ssl:send(
                    Socket, <<"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n">>
                ),
                case recv_all(Socket, <<>>) of
                    {ok, Response} -> body_h1(Response);
                    {error, _} = Error -> Error
                end
            after
                _ = ssl:close(Socket)
            end;
        {error, _} = Error ->
            Error
    end.

recv_all(Socket, Acc) ->
    case ssl:recv(Socket, 0, 5000) of
        {ok, Data} -> recv_all(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} when Acc =/= <<>> -> {ok, Acc};
        {error, Reason} -> {error, Reason}
    end.

body_h1(Response) ->
    [Head, Body] = binary:split(Response, <<"\r\n\r\n">>),
    <<"HTTP/1.1 200", _/binary>> = Head,
    {ok, binary_to_term(Body)}.

fetch_h2(Port, ClientOpts) ->
    process_flag(trap_exit, true),
    Opts = #{transport => ssl, ssl_opts => ssl_client_opts(ClientOpts)},
    case catch h2:connect("127.0.0.1", Port, Opts) of
        {ok, Conn} ->
            try h2:request(Conn, <<"GET">>, <<"/">>, [{<<"host">>, <<"localhost">>}]) of
                {ok, StreamId} -> collect_h2(Conn, StreamId, <<>>);
                {error, _} = Error -> Error
            catch
                exit:Reason -> {error, Reason}
            after
                catch h2:close(Conn)
            end;
        {error, _} = Error ->
            Error;
        {'EXIT', Reason} ->
            {error, Reason}
    end.

collect_h2(Conn, StreamId, Acc) ->
    receive
        {h2, Conn, {data, StreamId, Chunk, true}} ->
            {ok, binary_to_term(<<Acc/binary, Chunk/binary>>)};
        {h2, Conn, {data, StreamId, Chunk, false}} ->
            collect_h2(Conn, StreamId, <<Acc/binary, Chunk/binary>>);
        {h2, Conn, {closed, Reason}} ->
            {error, Reason};
        {h2, Conn, {stream_reset, StreamId, Reason}} ->
            {error, Reason};
        {h2, Conn, _Other} ->
            collect_h2(Conn, StreamId, Acc);
        {'EXIT', Conn, Reason} ->
            {error, Reason}
    after 5000 ->
        {error, timeout}
    end.

fetch_h3(Port, ClientOpts) ->
    Opts0 = #{verify => verify_none, sync => true},
    Opts =
        case ClientOpts of
            [] ->
                Opts0;
            _ ->
                {KeyType, KeyDer} = proplists:get_value(key, ClientOpts),
                Opts0#{
                    cert => proplists:get_value(cert, ClientOpts),
                    key => public_key:der_decode(KeyType, KeyDer)
                }
        end,
    case quic_h3:connect(<<"localhost">>, Port, Opts) of
        {ok, Conn} ->
            try
                Headers = [
                    {<<":method">>, <<"GET">>},
                    {<<":path">>, <<"/">>},
                    {<<":scheme">>, <<"https">>},
                    {<<":authority">>, <<"localhost">>}
                ],
                case quic_h3:request(Conn, Headers, #{end_stream => true}) of
                    {ok, StreamId} -> collect_h3(Conn, StreamId, <<>>);
                    {error, _} = Error -> Error
                end
            catch
                exit:Reason -> {error, Reason}
            after
                catch quic_h3:close(Conn)
            end;
        {error, _} = Error ->
            Error
    end.

collect_h3(Conn, StreamId, Acc) ->
    receive
        {quic_h3, Conn, {data, StreamId, Chunk, true}} ->
            {ok, binary_to_term(<<Acc/binary, Chunk/binary>>)};
        {quic_h3, Conn, {data, StreamId, Chunk, false}} ->
            collect_h3(Conn, StreamId, <<Acc/binary, Chunk/binary>>);
        {quic_h3, Conn, {closed, Reason}} ->
            {error, Reason};
        {quic_h3, Conn, {stream_reset, StreamId, Reason}} ->
            {error, Reason};
        {quic_h3, Conn, _Other} ->
            collect_h3(Conn, StreamId, Acc)
    after 5000 ->
        {error, timeout}
    end.

%%====================================================================
%% Certificates
%%====================================================================

chain(SanNames) ->
    Key = {key, {namedCurve, secp256r1}},
    San = #'Extension'{
        extnID = ?'id-ce-subjectAltName',
        critical = false,
        extnValue = SanNames
    },
    %% The default digest is SHA-1, which TLS 1.3 refuses.
    Digest = {digest, sha256},
    #{root => [Key, Digest], intermediates => [], peer => [Key, Digest, {extensions, [San]}]}.
