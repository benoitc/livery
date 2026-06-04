%% @doc End-to-end journey against the example notes service.
%%
%% Boots `livery_example_complete' once over H1 (TCP), H2 (TLS), and H3
%% (QUIC) on ephemeral ports, then runs the same user journey over each
%% protocol with real native clients (hackney for H1, the `h2' and
%% `quic_h3' libraries for H2/H3, `ws'/`ws_frame' for WebSockets). This
%% exercises the full stack as a deployed unit: router, the service-wide
%% middleware (request id, timing) and a per-route middleware, JSON CRUD,
%% the SSE feed, and the WebSocket echo. Hermetic; no external tools.
-module(livery_e2e_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([journey/1, ws_echo/1]).

-define(TIMEOUT, 5000).
-define(WS_TIMEOUT, 15000).

all() ->
    [{group, h1}, {group, h2}, {group, h3}].

groups() ->
    Cases = [journey, ws_echo],
    [
        {h1, [sequence], Cases},
        {h2, [sequence], Cases},
        {h3, [sequence], Cases}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(hackney),
    {ok, CertDer, KeyDer} = livery_test_certs:load(),
    {CertFile, KeyFile} = livery_test_certs:paths(),
    %% The example owns the notes ETS table and the router/middleware; we
    %% start the service ourselves so we can bind ephemeral ports and turn
    %% on extended CONNECT for WebSockets over H2/H3. The notes table must
    %% outlive the transient init_per_suite process, so a keeper owns it.
    Keeper = spawn_table_keeper(),
    {ok, Pid} = livery:start_service(#{
        host => <<"localhost">>,
        http => #{port => 0},
        https => #{
            port => 0,
            cert => CertFile,
            key => KeyFile,
            transport => ssl,
            enable_connect_protocol => true
        },
        http3 => #{
            port => 0,
            cert => CertDer,
            key => KeyDer,
            settings => #{enable_connect_protocol => 1}
        },
        middleware => livery_example_complete:base_stack(),
        router => livery_example_complete:router(),
        alt_svc => advertise
    }),
    %% start_service links to us; survive init_per_suite for the suite.
    true = unlink(Pid),
    Listeners = livery:which_listeners(Pid),
    %% Fail fast if a protocol did not come up, rather than silently
    %% testing fewer than three.
    #{h1 := _, h2 := _, h3 := _} = Listeners,
    [{service, Pid}, {keeper, Keeper}, {listeners, Listeners} | Config].

end_per_suite(Config) ->
    catch livery:stop_service(?config(service, Config)),
    %% Killing the keeper drops the notes table it owns.
    catch exit(?config(keeper, Config), kill),
    ok.

%% Own the notes ETS table from a process that lives for the whole suite,
%% and block until it exists so the first request finds it.
spawn_table_keeper() ->
    Self = self(),
    Keeper = spawn(fun() ->
        ok = livery_example_complete:ensure_table(),
        Self ! {table_ready, self()},
        receive
            stop -> ok
        end
    end),
    receive
        {table_ready, Keeper} -> Keeper
    after ?TIMEOUT -> error(table_keeper_timeout)
    end.

init_per_group(Proto, Config) ->
    [{proto, Proto} | Config].

end_per_group(_Proto, _Config) ->
    ok.

%%====================================================================
%% The journey: CRUD + list (with middleware headers) + SSE
%%====================================================================

journey(Config) ->
    Tag = atom_to_binary(?config(proto, Config), utf8),
    Text = <<"note-", Tag/binary>>,

    %% 1. Create. json:encode returns iodata; flatten so byte_size works.
    CreateReq = iolist_to_binary(json:encode(#{<<"text">> => Text})),
    {201, CreateHs, CreateBody} = req(Config, <<"POST">>, <<"/notes">>, CreateReq),
    Note = json:decode(CreateBody),
    Id = maps:get(<<"id">>, Note),
    ?assertEqual(Text, maps:get(<<"text">>, Note)),
    ?assertEqual(<<"/notes/", Id/binary>>, header(<<"location">>, CreateHs)),

    %% 2. Fetch it back.
    Path = <<"/notes/", Id/binary>>,
    {200, _, ShowBody} = req(Config, <<"GET">>, Path, <<>>),
    ?assertEqual(Text, maps:get(<<"text">>, json:decode(ShowBody))),

    %% 3. List: our note is there, and the middleware stack ran end to end.
    {200, ListHs, ListBody} = req(Config, <<"GET">>, <<"/notes">>, <<>>),
    Ids = [maps:get(<<"id">>, N) || N <- json:decode(ListBody)],
    ?assert(lists:member(Id, Ids)),
    ?assertEqual(<<"notes">>, header(<<"x-list">>, ListHs)),
    ?assertNotEqual(undefined, header(<<"x-request-id">>, ListHs)),
    ?assertNotEqual(undefined, header(<<"x-response-time-ms">>, ListHs)),

    %% 4. Delete.
    {204, _, DeleteBody} = req(Config, <<"DELETE">>, Path, <<>>),
    ?assertEqual(<<>>, DeleteBody),

    %% 5. Gone.
    {404, _, _} = req(Config, <<"GET">>, Path, <<>>),

    %% 6. SSE feed: three `event: notes' frames, then the stream ends.
    {200, EventsHs, EventsBody} = req(Config, <<"GET">>, <<"/events">>, <<>>),
    ?assertEqual(<<"text/event-stream">>, header(<<"content-type">>, EventsHs)),
    ?assert(count_occurrences(EventsBody, <<"event: notes">>) >= 3).

%%====================================================================
%% WebSocket echo over each protocol
%%====================================================================

ws_echo(Config) ->
    Proto = ?config(proto, Config),
    Frame = <<"hi-", (atom_to_binary(Proto, utf8))/binary>>,
    case Proto of
        h1 -> ws_echo_h1(port(Config, h1), Frame);
        h2 -> ws_echo_h2(port(Config, h2), Frame);
        h3 -> ws_echo_h3(port(Config, h3), Frame)
    end.

ws_echo_h1(Port, Frame) ->
    Self = self(),
    Url = iolist_to_binary([<<"ws://127.0.0.1:">>, integer_to_binary(Port), <<"/ws">>]),
    {ok, Sess} = ws_client:connect(Url, #{
        handler => livery_ws_client_capture,
        handler_opts => #{parent => Self}
    }),
    try
        ok = ws:send(Sess, [{text, Frame}]),
        receive
            {captured, {text, Frame}} -> ok
        after ?WS_TIMEOUT -> ct:fail(no_echo_over_h1)
        end
    after
        catch ws:close(Sess, 1000, <<"bye">>),
        catch ws:stop(Sess)
    end.

ws_echo_h2(Port, Frame) ->
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{
        transport => ssl,
        ssl_opts => [{verify, verify_none}, {server_name_indication, "localhost"}]
    }),
    try
        {ok, StreamId} = h2:request(
            Conn,
            [
                {<<":method">>, <<"CONNECT">>},
                {<<":scheme">>, <<"https">>},
                {<<":authority">>, <<"localhost">>},
                {<<":path">>, <<"/ws">>},
                {<<"sec-websocket-version">>, <<"13">>}
            ],
            #{protocol => <<"websocket">>}
        ),
        200 = wait_ws_status(h2, Conn, StreamId),
        Wire = iolist_to_binary(ws_frame:encode({text, Frame}, client)),
        ok = h2:send_data(Conn, StreamId, Wire, false),
        Parser = ws_frame:init_parser(#{role => client}),
        {Echo, _} = recv_ws_frame(h2, Conn, StreamId, Parser),
        ?assertEqual({text, Frame}, Echo)
    after
        h2:close(Conn)
    end.

ws_echo_h3(Port, Frame) ->
    {ok, Conn} = quic_h3:connect(<<"localhost">>, Port, #{
        verify => verify_none,
        sync => true,
        settings => #{enable_connect_protocol => 1}
    }),
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
        200 = wait_ws_status(h3, Conn, StreamId),
        Wire = iolist_to_binary(ws_frame:encode({text, Frame}, client)),
        ok = quic_h3:send_data(Conn, StreamId, Wire, false),
        Parser = ws_frame:init_parser(#{role => client}),
        {Echo, _} = recv_ws_frame(h3, Conn, StreamId, Parser),
        ?assertEqual({text, Frame}, Echo)
    after
        catch quic_h3:close(Conn)
    end.

%%====================================================================
%% Request helpers, one per protocol, all returning {Status, Headers, Body}
%%====================================================================

req(Config, Method, Path, Body) ->
    case ?config(proto, Config) of
        h1 -> req_h1(port(Config, h1), Method, Path, Body);
        h2 -> req_h2(port(Config, h2), Method, Path, Body);
        h3 -> req_h3(port(Config, h3), Method, Path, Body)
    end.

req_h1(Port, Method, Path, Body) ->
    Url = iolist_to_binary([<<"http://127.0.0.1:">>, integer_to_binary(Port), Path]),
    Headers = body_headers(Body),
    {ok, Status, RespHeaders, RespBody} =
        hackney:request(Method, Url, Headers, Body, [with_body, {recv_timeout, ?TIMEOUT}]),
    {Status, normalize(RespHeaders), RespBody}.

req_h2(Port, Method, Path, Body) ->
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{
        transport => ssl,
        ssl_opts => [{verify, verify_none}, {server_name_indication, "localhost"}]
    }),
    Base = [{<<"host">>, <<"localhost">>}],
    {ok, StreamId} =
        case byte_size(Body) of
            0 ->
                h2:request(Conn, Method, Path, Base);
            N ->
                h2:request(
                    Conn, Method, Path, Base ++ [{<<"content-length">>, integer_to_binary(N)}], Body
                )
        end,
    Result = collect(h2, Conn, StreamId, undefined, [], []),
    h2:close(Conn),
    Result.

req_h3(Port, Method, Path, Body) ->
    {ok, Conn} = quic_h3:connect(<<"localhost">>, Port, #{verify => verify_none, sync => true}),
    try
        Base = [
            {<<":method">>, Method},
            {<<":path">>, Path},
            {<<":scheme">>, <<"https">>},
            {<<":authority">>, <<"localhost">>}
        ],
        case byte_size(Body) of
            0 ->
                {ok, StreamId} = quic_h3:request(Conn, Base, #{end_stream => true}),
                collect(h3, Conn, StreamId, undefined, [], []);
            N ->
                Hs = Base ++ [{<<"content-length">>, integer_to_binary(N)}],
                {ok, StreamId} = quic_h3:request(Conn, Hs, #{end_stream => false}),
                ok = quic_h3:send_data(Conn, StreamId, Body, true),
                collect(h3, Conn, StreamId, undefined, [], [])
        end
    after
        catch quic_h3:close(Conn)
    end.

%% Drive the H2/H3 native client receive loop to a full buffered response.
collect(Proto, Conn, StreamId, Status, Headers, BodyAcc) ->
    {Tag, End} = proto_msgs(Proto),
    receive
        {Tag, Conn, {response, StreamId, S, Hs}} ->
            collect(Proto, Conn, StreamId, S, Hs, BodyAcc);
        {Tag, Conn, {data, StreamId, Chunk, false}} ->
            collect(Proto, Conn, StreamId, Status, Headers, [Chunk | BodyAcc]);
        {Tag, Conn, {data, StreamId, Chunk, true}} ->
            done(Status, Headers, [Chunk | BodyAcc]);
        {Tag, Conn, {End, StreamId}} ->
            done(Status, Headers, BodyAcc);
        {Tag, Conn, _Other} ->
            collect(Proto, Conn, StreamId, Status, Headers, BodyAcc)
    after ?TIMEOUT ->
        {error, timeout}
    end.

done(Status, Headers, BodyAcc) ->
    {Status, normalize(Headers), iolist_to_binary(lists:reverse(BodyAcc))}.

%%====================================================================
%% WebSocket frame receive (H2/H3 share the shape, only the tag differs)
%%====================================================================

wait_ws_status(Proto, Conn, StreamId) ->
    {Tag, _} = proto_msgs(Proto),
    receive
        {Tag, Conn, {response, StreamId, Status, _Hs}} -> Status;
        {Tag, Conn, _Other} -> wait_ws_status(Proto, Conn, StreamId)
    after ?WS_TIMEOUT -> ct:fail(no_ws_status)
    end.

recv_ws_frame(Proto, Conn, StreamId, Parser) ->
    {Tag, _} = proto_msgs(Proto),
    receive
        {Tag, Conn, {data, StreamId, Bin, _Fin}} ->
            case ws_frame:parse(Parser, Bin) of
                {ok, [Frame | _], P} -> {Frame, P};
                {ok, [], P} -> recv_ws_frame(Proto, Conn, StreamId, P)
            end;
        {Tag, Conn, _Other} ->
            recv_ws_frame(Proto, Conn, StreamId, Parser)
    after ?WS_TIMEOUT ->
        ct:fail(no_ws_frame)
    end.

%%====================================================================
%% Small helpers
%%====================================================================

proto_msgs(h2) -> {h2, ignore};
proto_msgs(h3) -> {quic_h3, stream_end}.

port(Config, Proto) -> maps:get(Proto, ?config(listeners, Config)).

body_headers(<<>>) -> [];
body_headers(_Body) -> [{<<"content-type">>, <<"application/json">>}].

normalize(Headers) ->
    [{string:lowercase(N), V} || {N, V} <- Headers].

header(Name, Headers) ->
    case lists:keyfind(string:lowercase(Name), 1, Headers) of
        {_, Value} -> Value;
        false -> undefined
    end.

count_occurrences(Subject, Pattern) ->
    case binary:matches(Subject, Pattern) of
        nomatch -> 0;
        Matches -> length(Matches)
    end.
