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
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    h1_echo_text_frame/1,
    h1_rejects_request_without_upgrade_headers/1,
    h2_echo_text_frame/1,
    h2_rejects_plain_get/1,
    h3_echo_text_frame/1
]).

%%====================================================================
%% Suite plumbing
%%====================================================================

all() ->
    [h1_echo_text_frame,
     h1_rejects_request_without_upgrade_headers,
     h2_echo_text_frame,
     h2_rejects_plain_get,
     h3_echo_text_frame].

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

init_per_testcase(TC, Config) when TC =:= h2_echo_text_frame;
                                   TC =:= h2_rejects_plain_get ->
    {ok, Listener} = livery_h2:start(#{
        port                    => 0,
        transport               => tcp,
        enable_connect_protocol => true,
        stack                   => [],
        handler                 => fun ws_handler/1
    }),
    [{adapter, h2}, {listener, Listener},
     {port, h2:server_port(Listener)} | Config];
init_per_testcase(h3_echo_text_frame, Config) ->
    {ok, Listener} = livery_h3:start(#{
        port     => 0,
        cert     => ?config(cert, Config),
        key      => ?config(key, Config),
        settings => #{enable_connect_protocol => 1},
        stack    => [],
        handler  => fun ws_handler/1
    }),
    {ok, Port} = quic:get_server_port(Listener),
    [{adapter, h3}, {listener, Listener}, {port, Port} | Config];
init_per_testcase(_TC, Config) ->
    {ok, Listener} = livery_h1:start(#{
        port    => 0,
        stack   => [],
        handler => fun ws_handler/1
    }),
    [{adapter, h1}, {listener, Listener},
     {port, h1:server_port(Listener)} | Config].

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

%%====================================================================
%% H1
%%====================================================================

h1_echo_text_frame(Config) ->
    Port = ?config(port, Config),
    Url = iolist_to_binary([<<"ws://127.0.0.1:">>,
                            integer_to_binary(Port), <<"/">>]),
    Self = self(),
    {ok, Sess} = ws_client:connect(Url, #{
        handler      => livery_ws_client_capture,
        handler_opts => #{parent => Self}
    }),
    try
        ok = ws:send(Sess, [{text, <<"hello">>}]),
        receive
            {captured, {text, <<"hello">>}} -> ok
        after 2000 -> ct:fail(no_echo_frame)
        end
    after
        catch ws:close(Sess, 1000, <<"bye">>),
        catch ws:stop(Sess)
    end.

h1_rejects_request_without_upgrade_headers(Config) ->
    Port = ?config(port, Config),
    Url = iolist_to_binary([<<"http://127.0.0.1:">>,
                            integer_to_binary(Port), <<"/">>]),
    {ok, Status, _Headers, Body} =
        hackney:request(<<"GET">>, Url, [], <<>>,
                        [with_body, {recv_timeout, 5000}]),
    ?assertEqual(400, Status),
    ?assertMatch(<<"bad ws upgrade:", _/binary>>, Body).

%%====================================================================
%% H2 (RFC 8441 extended CONNECT)
%%====================================================================

h2_echo_text_frame(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    try
        {ok, StreamId} = h2:request(Conn, [
            {<<":method">>, <<"CONNECT">>},
            {<<":scheme">>, <<"http">>},
            {<<":authority">>, <<"localhost">>},
            {<<":path">>, <<"/ws">>},
            {<<"sec-websocket-version">>, <<"13">>}
        ], #{protocol => <<"websocket">>}),
        %% Extended CONNECT succeeds with a 200 response.
        200 = wait_h2_status(Conn, StreamId),
        %% Send a masked client text frame as h2 DATA.
        Frame = iolist_to_binary(ws_frame:encode({text, <<"over-h2">>}, client)),
        ok = h2:send_data(Conn, StreamId, Frame, false),
        %% Receive the echoed (unmasked, server-role) frame.
        Echo = recv_ws_frame(Conn, StreamId, ws_frame:init_parser(#{role => client})),
        ?assertEqual({text, <<"over-h2">>}, Echo)
    after
        h2:close(Conn)
    end.

h2_rejects_plain_get(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    try
        {ok, StreamId} = h2:request(Conn, <<"GET">>, <<"/">>,
                                    [{<<"host">>, <<"localhost">>}]),
        %% A plain GET hits the upgrade handler, which can't find WS
        %% upgrade headers and returns 400.
        ?assertEqual(400, wait_h2_status(Conn, StreamId))
    after
        h2:close(Conn)
    end.

%%====================================================================
%% H3 (RFC 9220 extended CONNECT)
%%====================================================================

h3_echo_text_frame(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = quic_h3:connect(<<"localhost">>, Port,
                                  #{verify => verify_none, sync => true,
                                    settings => #{enable_connect_protocol => 1}}),
    try
        {ok, StreamId} = quic_h3:request(Conn, [
            {<<":method">>, <<"CONNECT">>},
            {<<":protocol">>, <<"websocket">>},
            {<<":scheme">>, <<"https">>},
            {<<":authority">>, <<"localhost">>},
            {<<":path">>, <<"/ws">>},
            {<<"sec-websocket-version">>, <<"13">>}
        ], #{end_stream => false}),
        200 = wait_h3_status(Conn, StreamId),
        Frame = iolist_to_binary(ws_frame:encode({text, <<"over-h3">>}, client)),
        ok = quic_h3:send_data(Conn, StreamId, Frame, false),
        Echo = recv_ws_frame_h3(Conn, StreamId,
                                ws_frame:init_parser(#{role => client})),
        ?assertEqual({text, <<"over-h3">>}, Echo)
    after
        catch quic_h3:close(Conn)
    end.

wait_h3_status(Conn, StreamId) ->
    receive
        {quic_h3, Conn, {response, StreamId, Status, _Hs}} -> Status;
        {quic_h3, Conn, _Other} -> wait_h3_status(Conn, StreamId)
    after 5000 -> ct:fail(h3_no_response)
    end.

recv_ws_frame_h3(Conn, StreamId, Parser) ->
    receive
        {quic_h3, Conn, {data, StreamId, Bin, _Fin}} ->
            case ws_frame:parse(Parser, Bin) of
                {ok, [Frame | _], _P} -> Frame;
                {ok, [], P}           -> recv_ws_frame_h3(Conn, StreamId, P)
            end;
        {quic_h3, Conn, _Other} ->
            recv_ws_frame_h3(Conn, StreamId, Parser)
    after 5000 ->
        ct:fail(no_ws_frame_over_h3)
    end.

%%====================================================================
%% H2 client helpers
%%====================================================================

wait_h2_status(Conn, StreamId) ->
    receive
        {h2, Conn, {response, StreamId, Status, _Hs}} -> Status;
        {h2, Conn, _Other} -> wait_h2_status(Conn, StreamId)
    after 5000 -> ct:fail(h2_no_response)
    end.

recv_ws_frame(Conn, StreamId, Parser) ->
    receive
        {h2, Conn, {data, StreamId, Bin, _Fin}} ->
            case ws_frame:parse(Parser, Bin) of
                {ok, [Frame | _], _P} -> Frame;
                {ok, [], P}           -> recv_ws_frame(Conn, StreamId, P)
            end;
        {h2, Conn, _Other} ->
            recv_ws_frame(Conn, StreamId, Parser)
    after 5000 ->
        ct:fail(no_ws_frame_over_h2)
    end.
