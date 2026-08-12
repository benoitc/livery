%% @doc One TLS port serving HTTP/2 and HTTP/1.1, chosen by ALPN.
%%
%% Brings up a service whose `https' listener advertises
%% `[h2, http1]', then dials it three ways: offering both protocols
%% (h2 must win), offering only `http/1.1', and offering no ALPN at
%% all. Each connection must reach the same handler over the
%% protocol ALPN settled on, and `which_listeners/1' must report the
%% one port under both `h1' and `h2'.
-module(livery_alpn_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    both_offered_negotiates_h2/1,
    http1_only_client_is_served_by_h1/1,
    client_without_alpn_is_served_by_h1/1,
    which_listeners_reports_h1_and_h2_on_one_port/1,
    h2_only_default_leaves_http1_unserved/1,
    cleartext_http_keeps_its_own_h1_port/1,
    stop_accepting_refuses_new_connections/1
]).

-define(H2, <<"h2">>).
-define(HTTP1, <<"http/1.1">>).

%%====================================================================
%% Suite plumbing
%%====================================================================

all() ->
    [
        both_offered_negotiates_h2,
        http1_only_client_is_served_by_h1,
        client_without_alpn_is_served_by_h1,
        which_listeners_reports_h1_and_h2_on_one_port,
        h2_only_default_leaves_http1_unserved,
        cleartext_http_keeps_its_own_h1_port,
        stop_accepting_refuses_new_connections
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(h1),
    {ok, _} = application:ensure_all_started(h2),
    {CertFile, KeyFile} = livery_test_certs:paths(),
    [{cert_file, CertFile}, {key_file, KeyFile} | Config].

end_per_suite(_Config) ->
    _ = application:stop(h2),
    _ = application:stop(h1),
    _ = application:stop(livery),
    ok.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

%%====================================================================
%% Cases
%%====================================================================

%% The server lists h2 first, so a client offering both gets h2 and the
%% request runs through the H2 adapter.
both_offered_negotiates_h2(Config) ->
    with_service(Config, [h2, http1], fun(_Pid, Ports) ->
        Port = alpn_port(Ports),
        ?assertEqual({ok, ?H2}, negotiated(Port, [?H2, ?HTTP1])),
        ?assertEqual(<<"h2 h2">>, body_via_h2(Port))
    end).

http1_only_client_is_served_by_h1(Config) ->
    with_service(Config, [h2, http1], fun(_Pid, Ports) ->
        Port = alpn_port(Ports),
        ?assertEqual({ok, ?HTTP1}, negotiated(Port, [?HTTP1])),
        ?assertEqual({200, <<"h1 http/1.1">>}, body_via_h1(Port, [?HTTP1]))
    end).

%% RFC 9113 requires ALPN to reach h2 over TLS, so a client that offers
%% none is HTTP/1.1 and must be served, not dropped.
client_without_alpn_is_served_by_h1(Config) ->
    with_service(Config, [h2, http1], fun(_Pid, Ports) ->
        Port = alpn_port(Ports),
        ?assertEqual({error, protocol_not_negotiated}, negotiated(Port, undefined)),
        %% Nothing was negotiated, so the request reports no ALPN.
        ?assertEqual({200, <<"h1 none">>}, body_via_h1(Port, undefined))
    end).

which_listeners_reports_h1_and_h2_on_one_port(Config) ->
    with_service(Config, [h2, http1], fun(_Pid, Ports) ->
        Port = alpn_port(Ports),
        ?assertEqual(#{h1 => [Port], h2 => [Port]}, Ports)
    end).

%% The default is unchanged: `https' without `alpn' is an h2-only
%% listener, and an http/1.1-only client cannot complete a handshake.
h2_only_default_leaves_http1_unserved(Config) ->
    with_service(Config, default, fun(_Pid, Ports) ->
        Port = hd(maps:get(h2, Ports)),
        ?assertEqual([h2], maps:keys(Ports)),
        ?assertEqual({ok, ?H2}, negotiated(Port, [?H2])),
        ?assertMatch({error, _}, negotiated(Port, [?HTTP1]))
    end).

%% An ALPN listener alongside a cleartext `http' listener puts HTTP/1.1
%% on two ports, and both are reported.
cleartext_http_keeps_its_own_h1_port(Config) ->
    {ok, Pid} = livery:start_service(#{
        http => #{port => 0},
        https => https_opts(Config, [h2, http1]),
        handler => fun handler/1
    }),
    try
        #{h1 := H1Ports, h2 := [TlsPort]} = livery:which_listeners(Pid),
        ?assertEqual(2, length(H1Ports)),
        ?assert(lists:member(TlsPort, H1Ports)),
        [Cleartext] = H1Ports -- [TlsPort],
        ?assertEqual({200, <<"h1 none">>}, body_via_tcp(Cleartext))
    after
        livery:stop_service(Pid)
    end.

%% Draining closes the listen socket while the service stays up, so a
%% fresh dial is refused on both protocols.
stop_accepting_refuses_new_connections(Config) ->
    with_service(Config, [h2, http1], fun(Pid, Ports) ->
        Port = alpn_port(Ports),
        ?assertEqual({ok, ?H2}, negotiated(Port, [?H2, ?HTTP1])),
        ok = livery_service:stop_accepting(Pid),
        ?assertMatch({error, _}, negotiated(Port, [?H2, ?HTTP1])),
        ?assertMatch({error, _}, negotiated(Port, [?HTTP1]))
    end).

%%====================================================================
%% Fixtures
%%====================================================================

%% The handler echoes the protocol the adapter reports and the ALPN the
%% connection actually negotiated, so a case can tell which library
%% served it without inspecting the wire.
handler(Req) ->
    Adapter = livery_req:adapter(Req),
    #{alpn := Alpn} = Adapter:peer_info(livery_req:stream(Req)),
    Body = iolist_to_binary([
        atom_to_binary(livery_req:protocol(Req)),
        <<" ">>,
        case Alpn of
            undefined -> <<"none">>;
            _ -> Alpn
        end
    ]),
    livery_resp:text(200, Body).

https_opts(Config, default) ->
    #{
        port => 0,
        cert => ?config(cert_file, Config),
        key => ?config(key_file, Config)
    };
https_opts(Config, Alpn) ->
    (https_opts(Config, default))#{alpn => Alpn}.

%% The callback gets the service pid and its listener map; the service
%% is stopped afterwards either way.
with_service(Config, Alpn, Fun) ->
    {ok, Pid} = livery:start_service(#{
        https => https_opts(Config, Alpn),
        handler => fun handler/1
    }),
    try
        Fun(Pid, livery:which_listeners(Pid))
    after
        livery:stop_service(Pid)
    end.

alpn_port(#{h1 := [Port], h2 := [Port]}) -> Port.

%%====================================================================
%% Clients
%%====================================================================

%% Dial and report only what ALPN settled on. `undefined' advertises
%% nothing, which is how a pre-ALPN client looks on the wire.
negotiated(Port, Advertised) ->
    case ssl:connect("127.0.0.1", Port, client_opts(Advertised), 5000) of
        {ok, Socket} ->
            Result = ssl:negotiated_protocol(Socket),
            _ = ssl:close(Socket),
            Result;
        {error, _} = Error ->
            Error
    end.

client_opts(undefined) ->
    [
        binary,
        {active, false},
        {verify, verify_none},
        {server_name_indication, "localhost"}
    ];
client_opts(Advertised) ->
    [{alpn_advertised_protocols, Advertised} | client_opts(undefined)].

%% Speak HTTP/1.1 by hand rather than through a client library, so the
%% test controls exactly what ALPN the ClientHello carries.
body_via_h1(Port, Advertised) ->
    {ok, Socket} = ssl:connect("127.0.0.1", Port, client_opts(Advertised), 5000),
    try
        ok = ssl:send(Socket, <<
            "GET / HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Connection: close\r\n\r\n"
        >>),
        parse_http1(recv_all(Socket, <<>>))
    after
        _ = ssl:close(Socket)
    end.

body_via_tcp(Port) ->
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000),
    try
        ok = gen_tcp:send(Socket, <<
            "GET / HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Connection: close\r\n\r\n"
        >>),
        parse_http1(recv_all_tcp(Socket, <<>>))
    after
        _ = gen_tcp:close(Socket)
    end.

recv_all(Socket, Acc) ->
    case ssl:recv(Socket, 0, 5000) of
        {ok, Data} -> recv_all(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, Reason} -> error({recv_failed, Reason})
    end.

recv_all_tcp(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} -> recv_all_tcp(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, Reason} -> error({recv_failed, Reason})
    end.

%% `Connection: close' means the body runs to EOF, so everything after
%% the header block is the body.
parse_http1(Response) ->
    [Head, Body] = binary:split(Response, <<"\r\n\r\n">>),
    [StatusLine | _] = binary:split(Head, <<"\r\n">>),
    [_Version, Status | _] = binary:split(StatusLine, <<" ">>, [global]),
    {binary_to_integer(Status), Body}.

body_via_h2(Port) ->
    {ok, Conn} = h2:connect(
        "127.0.0.1",
        Port,
        #{
            transport => ssl,
            ssl_opts => [
                {verify, verify_none},
                {server_name_indication, "localhost"}
            ]
        }
    ),
    try
        {ok, StreamId} = h2:request(
            Conn,
            <<"GET">>,
            <<"/">>,
            [{<<"host">>, <<"localhost">>}]
        ),
        collect_h2(Conn, StreamId, [])
    after
        h2:close(Conn)
    end.

collect_h2(Conn, StreamId, Acc) ->
    receive
        {h2, Conn, {data, StreamId, Chunk, true}} ->
            iolist_to_binary(lists:reverse([Chunk | Acc]));
        {h2, Conn, {data, StreamId, Chunk, false}} ->
            collect_h2(Conn, StreamId, [Chunk | Acc]);
        {h2, Conn, _Other} ->
            collect_h2(Conn, StreamId, Acc)
    after 5000 ->
        error(h2_timeout)
    end.
