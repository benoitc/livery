%% @doc CT suite for the WebSocket upgrade path.
%%
%% H1: a `livery_h1' listener whose handler upgrades via
%% `livery_ws:upgrade/3', driven by the `ws' library's H1 client.
%%
%% H2: a `livery_h2' listener with `enable_connect_protocol => true';
%% the test drives the RFC 8441 extended-CONNECT handshake and WS
%% framing manually over the h2 stream using `h2:request/3' (with the
%% `protocol' option) and `ws_frame'.
-module(livery_ws_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    suite/0,
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    h1_echo_text_frame/1,
    h1_ssl_echo_text_frame/1,
    h1_rejects_request_without_upgrade_headers/1,
    h1_echoes_subprotocol/1,
    h1_surfaces_peer/1,
    h1_idle_timeout_closes/1,
    h2_echo_text_frame/1,
    h2_rejects_plain_get/1,
    h2_surfaces_peer/1,
    h3_echo_text_frame/1,
    h3_surfaces_peer/1,
    h1_echo_text_frame_ipv6/1
]).

%%====================================================================
%% Suite plumbing
%%====================================================================

%% Bound every case so a wire-level stall (the in-VM QUIC path has hung
%% the ubuntu CI job for hours) fails fast instead of running to the
%% 30-minute CT default or the 6-hour GitHub job limit.
suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        h1_echo_text_frame,
        h1_ssl_echo_text_frame,
        h1_echo_text_frame_ipv6,
        h1_rejects_request_without_upgrade_headers,
        h1_echoes_subprotocol,
        h1_surfaces_peer,
        h1_idle_timeout_closes,
        h2_echo_text_frame,
        h2_rejects_plain_get,
        h2_surfaces_peer,
        h3_echo_text_frame,
        h3_surfaces_peer
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(h1),
    {ok, _} = application:ensure_all_started(h2),
    {ok, _} = application:ensure_all_started(quic),
    {ok, _} = application:ensure_all_started(ws),
    {ok, _} = application:ensure_all_started(hackney),
    {ok, CertDer, KeyDer} = livery_test_certs:load(),
    [{cert, CertDer}, {key, KeyDer} | Config].

end_per_suite(_Config) ->
    _ = application:stop(hackney),
    _ = application:stop(ws),
    _ = application:stop(quic),
    _ = application:stop(h2),
    _ = application:stop(h1),
    _ = application:stop(livery),
    ok.

init_per_testcase(TC, Config) when
    TC =:= h2_echo_text_frame;
    TC =:= h2_rejects_plain_get
->
    {ok, Listener} = livery_h2:start(#{
        port => 0,
        transport => tcp,
        enable_connect_protocol => true,
        stack => [],
        handler => fun ws_handler/1
    }),
    [
        {adapter, h2},
        {listener, Listener},
        {port, h2:server_port(Listener)}
        | Config
    ];
init_per_testcase(h2_surfaces_peer, Config) ->
    {ok, Listener} = livery_h2:start(#{
        port => 0,
        transport => tcp,
        enable_connect_protocol => true,
        stack => [],
        handler => fun ws_peer_handler/1
    }),
    [
        {adapter, h2},
        {listener, Listener},
        {port, h2:server_port(Listener)}
        | Config
    ];
init_per_testcase(h1_ssl_echo_text_frame, Config) ->
    {CertFile, KeyFile} = livery_test_certs:paths(),
    {ok, Listener} = livery_h1:start(#{
        port => 0,
        transport => ssl,
        cert => CertFile,
        key => KeyFile,
        stack => [],
        handler => fun ws_handler/1
    }),
    [
        {adapter, h1},
        {listener, Listener},
        {port, h1:server_port(Listener)}
        | Config
    ];
init_per_testcase(h1_echo_text_frame_ipv6, Config) ->
    case ipv6_loopback_available() of
        false ->
            {skip, no_ipv6_loopback};
        true ->
            {ok, Listener} = livery_h1:start(#{
                port => 0,
                ip => {0, 0, 0, 0, 0, 0, 0, 1},
                stack => [],
                handler => fun ws_handler/1
            }),
            [
                {adapter, h1},
                {listener, Listener},
                {port, h1:server_port(Listener)}
                | Config
            ]
    end;
init_per_testcase(h3_echo_text_frame, Config) ->
    {ok, Listener} = livery_h3:start(#{
        port => 0,
        cert => ?config(cert, Config),
        key => ?config(key, Config),
        settings => #{enable_connect_protocol => 1},
        stack => [],
        handler => fun ws_handler/1
    }),
    {ok, Port} = quic:get_server_port(Listener),
    [{adapter, h3}, {listener, Listener}, {port, Port} | Config];
init_per_testcase(h3_surfaces_peer, Config) ->
    {ok, Listener} = livery_h3:start(#{
        port => 0,
        cert => ?config(cert, Config),
        key => ?config(key, Config),
        settings => #{enable_connect_protocol => 1},
        stack => [],
        handler => fun ws_peer_handler/1
    }),
    {ok, Port} = quic:get_server_port(Listener),
    [{adapter, h3}, {listener, Listener}, {port, Port} | Config];
init_per_testcase(TC, Config) when
    TC =:= h1_echoes_subprotocol;
    TC =:= h1_surfaces_peer;
    TC =:= h1_idle_timeout_closes
->
    Handler =
        case TC of
            h1_echoes_subprotocol -> fun ws_subproto_handler/1;
            h1_surfaces_peer -> fun ws_peer_handler/1;
            h1_idle_timeout_closes -> fun ws_idle_handler/1
        end,
    {ok, Listener} = livery_h1:start(#{
        port => 0,
        stack => [],
        handler => Handler
    }),
    [
        {adapter, h1},
        {listener, Listener},
        {port, h1:server_port(Listener)}
        | Config
    ];
init_per_testcase(_TC, Config) ->
    {ok, Listener} = livery_h1:start(#{
        port => 0,
        stack => [],
        handler => fun ws_handler/1
    }),
    [
        {adapter, h1},
        {listener, Listener},
        {port, h1:server_port(Listener)}
        | Config
    ].

end_per_testcase(_TC, Config) ->
    case ?config(adapter, Config) of
        h1 -> livery_h1:stop(?config(listener, Config));
        h2 -> livery_h2:stop(?config(listener, Config));
        h3 -> livery_h3:stop(?config(listener, Config))
    end,
    ok.

%% Shared handler: upgrade to the echo ws_handler.
ws_handler(R) ->
    livery_ws:upgrade(R, livery_ws_echo_handler, #{}).

%% Require the `sip' subprotocol so the 101 echoes it back.
ws_subproto_handler(R) ->
    livery_ws:upgrade(R, livery_ws_echo_handler, #{subprotocols => [<<"sip">>]}).

%% Probe handler reports the peer address it saw on the Req.
ws_peer_handler(R) ->
    livery_ws:upgrade(R, livery_ws_probe_handler, #{}).

%% Short idle timeout so an idle connection is closed quickly.
ws_idle_handler(R) ->
    livery_ws:upgrade(R, livery_ws_echo_handler, #{idle_timeout => 300}).

%% Probe the IPv6 loopback with a real connect round-trip, not just a
%% listen: CI runners can bind `::1' yet fail to connect to it. A false
%% here skips the case cleanly instead of crashing the listener start.
ipv6_loopback_available() ->
    Loopback = {0, 0, 0, 0, 0, 0, 0, 1},
    case gen_tcp:listen(0, [inet6, {ip, Loopback}, {active, false}]) of
        {ok, L} ->
            {ok, Port} = inet:port(L),
            Ok =
                case gen_tcp:connect(Loopback, Port, [inet6], 1000) of
                    {ok, C} ->
                        gen_tcp:close(C),
                        case gen_tcp:accept(L, 1000) of
                            {ok, A} ->
                                gen_tcp:close(A),
                                true;
                            {error, _} ->
                                false
                        end;
                    {error, _} ->
                        false
                end,
            gen_tcp:close(L),
            Ok;
        {error, _} ->
            false
    end.

drain_captured() ->
    receive
        {captured, _} -> drain_captured()
    after 0 -> ok
    end.

%%====================================================================
%% H1
%%====================================================================

h1_echo_text_frame(Config) ->
    Port = ?config(port, Config),
    Url = iolist_to_binary([
        <<"ws://127.0.0.1:">>,
        integer_to_binary(Port),
        <<"/">>
    ]),
    ?assertEqual(ok, ws_echo_roundtrip(Url)).

%% Same echo round-trip over TLS (`wss://'), proving the accepted SSL
%% socket is handed to the ws session with the matching transport after
%% the HTTP/1.1 upgrade. Retried like the IPv6 case, since the handshake
%% can stall transiently under CI load.
h1_ssl_echo_text_frame(Config) ->
    Port = ?config(port, Config),
    Url = iolist_to_binary([
        <<"wss://127.0.0.1:">>,
        integer_to_binary(Port),
        <<"/">>
    ]),
    ?assertEqual(ok, ws_echo_roundtrip(Url, #{ssl_opts => [{verify, verify_none}]}, 3)).

%% Same echo round-trip over an IPv6-bound listener (`ip => ::1'),
%% proving the listen-address options carry through to the WS upgrade.
%% The listener is bound v6 in init_per_testcase, which skips the case
%% on a host without an IPv6 loopback. The `::1' ws handshake is
%% intermittently slow on some CI runners (a connect that binds and
%% accepts TCP yet stalls the upgrade), so retry a transient stall with a
%% fresh session before failing instead of flaking on a single timeout.
h1_echo_text_frame_ipv6(Config) ->
    Port = ?config(port, Config),
    Url = iolist_to_binary([
        <<"ws://[::1]:">>,
        integer_to_binary(Port),
        <<"/">>
    ]),
    ?assertEqual(ok, ws_echo_roundtrip(Url, #{}, 3)).

%% Connect opts default to none; a single attempt unless a case asks for
%% retries. `Opts' is merged into the ws_client connect map (e.g. to pass
%% `ssl_opts' for `wss://'); `Attempts' is how many fresh sessions to try
%% before giving up.
ws_echo_roundtrip(Url) ->
    ws_echo_roundtrip(Url, #{}, 1).

ws_echo_roundtrip(Url, Opts, Attempts) ->
    ws_echo_roundtrip(Url, Opts, Attempts, {error, not_attempted}).

ws_echo_roundtrip(_Url, _Opts, 0, Last) ->
    Last;
ws_echo_roundtrip(Url, Opts, N, _Last) ->
    case ws_echo_attempt(Url, Opts) of
        ok -> ok;
        {error, _} = E -> ws_echo_roundtrip(Url, Opts, N - 1, E)
    end.

%% One connect + ready + echo round-trip. Returns `ok' or `{error, Reason}'
%% (never raises), so the retry wrapper can try a fresh session. Drains any
%% frames captured during teardown so a retry starts with a clean mailbox.
ws_echo_attempt(Url, Opts) ->
    Self = self(),
    ConnectOpts = maps:merge(
        #{
            handler => livery_ws_client_capture,
            handler_opts => #{parent => Self}
        },
        Opts
    ),
    case ws_client:connect(Url, ConnectOpts) of
        {ok, Sess} ->
            try
                ws_echo_frames(Sess)
            after
                catch ws:close(Sess, 1000, <<"bye">>),
                catch ws:stop(Sess),
                drain_captured()
            end;
        {error, _} = E ->
            E
    end.

ws_echo_frames(Sess) ->
    %% The handler emits a `ready' frame on connect; wait for it so the
    %% stream is provably live before sending our own frame.
    receive
        {captured, {text, <<"ready">>}} ->
            ok = ws:send(Sess, [{text, <<"hello">>}]),
            receive
                {captured, {text, <<"hello">>}} -> ok
            after 15000 -> {error, no_echo_frame}
            end
    after 15000 -> {error, no_ready_frame}
    end.

h1_rejects_request_without_upgrade_headers(Config) ->
    Port = ?config(port, Config),
    Url = iolist_to_binary([
        <<"http://127.0.0.1:">>,
        integer_to_binary(Port),
        <<"/">>
    ]),
    {ok, Status, _Headers, Body} =
        hackney:request(
            <<"GET">>,
            Url,
            [],
            <<>>,
            [with_body, {recv_timeout, 5000}]
        ),
    ?assertEqual(400, Status),
    ?assertMatch(<<"bad ws upgrade:", _/binary>>, Body).

ws_url(Port) ->
    iolist_to_binary([<<"ws://127.0.0.1:">>, integer_to_binary(Port), <<"/">>]).

%% The server requires the `sip' subprotocol; the client offers it and must
%% see it echoed. The negotiated protocol reaches the client handler's
%% init/2 as Req = #{response := #{subprotocol := <<"sip">>}}.
h1_echoes_subprotocol(Config) ->
    Port = ?config(port, Config),
    Self = self(),
    {ok, Sess} = ws_client:connect(ws_url(Port), #{
        handler => livery_ws_client_capture,
        handler_opts => #{parent => Self},
        subprotocols => [<<"sip">>]
    }),
    try
        receive
            {ws_init, #{response := Response}} ->
                ?assertEqual(<<"sip">>, maps:get(subprotocol, Response, undefined))
        after 15000 ->
            ct:fail(no_ws_init)
        end
    after
        catch ws:close(Sess, 1000, <<"bye">>),
        catch ws:stop(Sess),
        drain_captured()
    end.

%% The probe handler emits the peer it saw on the Req; over loopback it must
%% be a real 127.0.0.1 address, proving the adapter surfaced it (not undefined).
h1_surfaces_peer(Config) ->
    Port = ?config(port, Config),
    Self = self(),
    {ok, Sess} = ws_client:connect(ws_url(Port), #{
        handler => livery_ws_client_capture,
        handler_opts => #{parent => Self}
    }),
    try
        receive
            {captured, {text, Peer}} ->
                ?assertMatch(<<"peer:127.0.0.1:", _/binary>>, Peer)
        after 15000 ->
            ct:fail(no_peer_frame)
        end
    after
        catch ws:close(Sess, 1000, <<"bye">>),
        catch ws:stop(Sess),
        drain_captured()
    end.

%% The server sets a 300ms idle timeout; the client sends nothing, so the
%% server closes the idle session (1001) and the client session ends. Proven
%% by the session pid going DOWN quickly (it would idle for 60s by default).
h1_idle_timeout_closes(Config) ->
    Port = ?config(port, Config),
    Self = self(),
    {ok, Sess} = ws_client:connect(ws_url(Port), #{
        handler => livery_ws_client_capture,
        handler_opts => #{parent => Self}
    }),
    MRef = monitor(process, Sess),
    try
        receive
            {captured, {text, <<"ready">>}} -> ok
        after 15000 -> ct:fail(no_ready_frame)
        end,
        receive
            {'DOWN', MRef, process, Sess, _} -> ok
        after 5000 -> ct:fail(no_idle_close)
        end
    after
        demonitor(MRef, [flush]),
        catch ws:close(Sess, 1000, <<"bye">>),
        catch ws:stop(Sess),
        drain_captured()
    end.

%%====================================================================
%% H2 (RFC 8441 extended CONNECT)
%%====================================================================

h2_echo_text_frame(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    try
        {ok, StreamId} = h2:request(
            Conn,
            [
                {<<":method">>, <<"CONNECT">>},
                {<<":scheme">>, <<"http">>},
                {<<":authority">>, <<"localhost">>},
                {<<":path">>, <<"/ws">>},
                {<<"sec-websocket-version">>, <<"13">>}
            ],
            #{protocol => <<"websocket">>}
        ),
        %% Extended CONNECT succeeds with a 200 response.
        200 = wait_h2_status(Conn, StreamId),
        %% Wait for the handler's `ready' frame so the stream is provably
        %% live before sending our own; thread the parser to the echo.
        Parser0 = ws_frame:init_parser(#{role => client}),
        {Ready, Parser1} = recv_ws_frame(Conn, StreamId, Parser0),
        ?assertEqual({text, <<"ready">>}, Ready),
        %% Send a masked client text frame as h2 DATA.
        Frame = iolist_to_binary(ws_frame:encode({text, <<"over-h2">>}, client)),
        ok = h2:send_data(Conn, StreamId, Frame, false),
        %% Receive the echoed (unmasked, server-role) frame.
        {Echo, _Parser2} = recv_ws_frame(Conn, StreamId, Parser1),
        ?assertEqual({text, <<"over-h2">>}, Echo)
    after
        h2:close(Conn)
    end.

h2_rejects_plain_get(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    try
        {ok, StreamId} = h2:request(
            Conn,
            <<"GET">>,
            <<"/">>,
            [{<<"host">>, <<"localhost">>}]
        ),
        %% A plain GET hits the upgrade handler, which can't find WS
        %% upgrade headers and returns 400.
        ?assertEqual(400, wait_h2_status(Conn, StreamId))
    after
        h2:close(Conn)
    end.

%% Over H2 the probe handler's first frame carries the peer address the
%% adapter read via h2:peername/1; assert it is a real address.
h2_surfaces_peer(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    try
        {ok, StreamId} = h2:request(
            Conn,
            [
                {<<":method">>, <<"CONNECT">>},
                {<<":scheme">>, <<"http">>},
                {<<":authority">>, <<"localhost">>},
                {<<":path">>, <<"/ws">>},
                {<<"sec-websocket-version">>, <<"13">>}
            ],
            #{protocol => <<"websocket">>}
        ),
        200 = wait_h2_status(Conn, StreamId),
        Parser0 = ws_frame:init_parser(#{role => client}),
        {{text, PeerFrame}, _Parser1} = recv_ws_frame(Conn, StreamId, Parser0),
        ?assertMatch(<<"peer:", _/binary>>, PeerFrame),
        ?assertNotEqual(<<"peer:undefined">>, PeerFrame)
    after
        h2:close(Conn)
    end.

%%====================================================================
%% H3 (RFC 9220 extended CONNECT)
%%====================================================================

h3_echo_text_frame(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = quic_h3:connect(
        <<"localhost">>,
        Port,
        #{
            verify => verify_none,
            sync => true,
            settings => #{enable_connect_protocol => 1}
        }
    ),
    try
        {ok, StreamId} = quic_h3:request(
            Conn,
            [
                {<<":method">>, <<"CONNECT">>},
                {<<":protocol">>, <<"websocket">>},
                {<<":scheme">>, <<"https">>},
                {<<":authority">>, <<"localhost">>},
                {<<":path">>, <<"/ws">>},
                {<<"sec-websocket-version">>, <<"13">>}
            ],
            #{end_stream => false}
        ),
        200 = wait_h3_status(Conn, StreamId),
        Parser0 = ws_frame:init_parser(#{role => client}),
        {Ready, Parser1} = recv_ws_frame_h3(Conn, StreamId, Parser0),
        ?assertEqual({text, <<"ready">>}, Ready),
        Frame = iolist_to_binary(ws_frame:encode({text, <<"over-h3">>}, client)),
        ok = quic_h3:send_data(Conn, StreamId, Frame, false),
        {Echo, _Parser2} = recv_ws_frame_h3(Conn, StreamId, Parser1),
        ?assertEqual({text, <<"over-h3">>}, Echo)
    after
        catch quic_h3:close(Conn)
    end.

%% Over H3 the probe handler's first frame carries the QUIC peer address;
%% assert it is a real address, proving quic_h3:get_quic_conn/1 +
%% quic_connection:peername/1 surfaced it (not undefined).
h3_surfaces_peer(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = quic_h3:connect(
        <<"localhost">>,
        Port,
        #{
            verify => verify_none,
            sync => true,
            settings => #{enable_connect_protocol => 1}
        }
    ),
    try
        {ok, StreamId} = quic_h3:request(
            Conn,
            [
                {<<":method">>, <<"CONNECT">>},
                {<<":protocol">>, <<"websocket">>},
                {<<":scheme">>, <<"https">>},
                {<<":authority">>, <<"localhost">>},
                {<<":path">>, <<"/ws">>},
                {<<"sec-websocket-version">>, <<"13">>}
            ],
            #{end_stream => false}
        ),
        200 = wait_h3_status(Conn, StreamId),
        Parser0 = ws_frame:init_parser(#{role => client}),
        {{text, PeerFrame}, _Parser1} = recv_ws_frame_h3(Conn, StreamId, Parser0),
        ?assertMatch(<<"peer:", _/binary>>, PeerFrame),
        ?assertNotEqual(<<"peer:undefined">>, PeerFrame)
    after
        catch quic_h3:close(Conn)
    end.

wait_h3_status(Conn, StreamId) ->
    receive
        {quic_h3, Conn, {response, StreamId, Status, _Hs}} -> Status;
        {quic_h3, Conn, _Other} -> wait_h3_status(Conn, StreamId)
    after 15000 -> ct:fail(h3_no_response)
    end.

%% Returns `{Frame, Parser}' so the parser (and any buffered bytes) can be
%% threaded across the `ready' frame and the subsequent echo.
recv_ws_frame_h3(Conn, StreamId, Parser) ->
    receive
        {quic_h3, Conn, {data, StreamId, Bin, _Fin}} ->
            case ws_frame:parse(Parser, Bin) of
                {ok, [Frame | _], P} -> {Frame, P};
                {ok, [], P} -> recv_ws_frame_h3(Conn, StreamId, P)
            end;
        {quic_h3, Conn, _Other} ->
            recv_ws_frame_h3(Conn, StreamId, Parser)
    after 15000 ->
        ct:fail(no_ws_frame_over_h3)
    end.

%%====================================================================
%% H2 client helpers
%%====================================================================

wait_h2_status(Conn, StreamId) ->
    receive
        {h2, Conn, {response, StreamId, Status, _Hs}} -> Status;
        {h2, Conn, _Other} -> wait_h2_status(Conn, StreamId)
    after 15000 -> ct:fail(h2_no_response)
    end.

%% Returns `{Frame, Parser}' so the parser (and any buffered bytes) can be
%% threaded across the `ready' frame and the subsequent echo.
recv_ws_frame(Conn, StreamId, Parser) ->
    receive
        {h2, Conn, {data, StreamId, Bin, _Fin}} ->
            case ws_frame:parse(Parser, Bin) of
                {ok, [Frame | _], P} -> {Frame, P};
                {ok, [], P} -> recv_ws_frame(Conn, StreamId, P)
            end;
        {h2, Conn, _Other} ->
            recv_ws_frame(Conn, StreamId, Parser)
    after 15000 ->
        ct:fail(no_ws_frame_over_h2)
    end.
