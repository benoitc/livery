%% @doc Cowboy cutover validation.
%%
%% Runs the same handler set (plain, REST resource, SSE, streaming
%% NDJSON, WebSocket echo) behind BOTH a live Cowboy listener and Livery,
%% and diffs the externally observable behaviour over H1 (hackney drives
%% both). This proves Livery is a drop-in Cowboy replacement.
%%
%% The "and you also get H2/H3" half is shown by driving the SAME Livery
%% handler over H2 and H3 (Cowboy speaks neither). Full H1/H2/H3 parity of
%% shared handlers lives in livery_parity_SUITE.
%%
%% The Livery handlers are examples/livery_example_migration.erl; the
%% Cowboy equivalents are the test-only cowboy_parity_*_h modules.
-module(livery_cowboy_parity_SUITE).

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
    plain_parity/1,
    things_list_parity/1,
    things_create_parity/1,
    thing_found_parity/1,
    thing_not_found_parity/1,
    things_method_not_allowed_parity/1,
    events_sse_parity/1,
    stream_ndjson_parity/1,
    ws_echo_parity/1,
    plain_over_h2/1,
    stream_over_h2/1,
    plain_over_h3/1
]).

-record(response, {
    status :: 100..599,
    headers = [] :: [{binary(), binary()}],
    body = <<>> :: binary()
}).

%%====================================================================
%% Suite plumbing
%%====================================================================

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        plain_parity,
        things_list_parity,
        things_create_parity,
        thing_found_parity,
        thing_not_found_parity,
        things_method_not_allowed_parity,
        events_sse_parity,
        stream_ndjson_parity,
        ws_echo_parity,
        plain_over_h2,
        stream_over_h2,
        plain_over_h3
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(h1),
    {ok, _} = application:ensure_all_started(h2),
    {ok, _} = application:ensure_all_started(quic),
    {ok, _} = application:ensure_all_started(ws),
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, CertDer, KeyDer} = livery_test_certs:load(),
    [{cert, CertDer}, {key, KeyDer} | Config].

end_per_suite(_Config) ->
    ok.

%% Listeners are started per test case: a listener started in
%% init_per_suite does not survive into the (separate) test-case process,
%% but init_per_testcase runs in the case process, so it does.
init_per_testcase(TC, Config) when TC =:= plain_over_h2; TC =:= stream_over_h2 ->
    {ok, H2} = livery_h2:start(#{
        port => 0, transport => tcp, stack => [], handler => livery_handler()
    }),
    [{h2_port, h2:server_port(H2)}, {h2_listener, H2} | Config];
init_per_testcase(plain_over_h3, Config) ->
    {ok, H3} = livery_h3:start(#{
        port => 0,
        cert => ?config(cert, Config),
        key => ?config(key, Config),
        stack => [],
        handler => livery_handler()
    }),
    {ok, Port} = quic:get_server_port(H3),
    [{h3_port, Port}, {h3_listener, H3} | Config];
init_per_testcase(_TC, Config) ->
    %% H1 parity + WebSocket cases: a Cowboy listener and a Livery H1
    %% listener, both serving the full route set.
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/plain", cowboy_parity_plain_h, []},
            {"/things", cowboy_parity_things_h, []},
            {"/things/:id", cowboy_parity_thing_h, []},
            {"/events", cowboy_parity_sse_h, []},
            {"/stream", cowboy_parity_stream_h, []},
            {"/ws", cowboy_parity_ws_h, []}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(
        ?MODULE, [{port, 0}], #{env => #{dispatch => Dispatch}}
    ),
    {ok, H1} = livery_h1:start(#{
        port => 0, stack => [], handler => livery_handler()
    }),
    [
        {cowboy_port, ranch:get_port(?MODULE)},
        {livery_port, h1:server_port(H1)},
        {h1_listener, H1}
        | Config
    ].

end_per_testcase(TC, Config) when TC =:= plain_over_h2; TC =:= stream_over_h2 ->
    _ = livery_h2:stop(?config(h2_listener, Config)),
    ok;
end_per_testcase(plain_over_h3, Config) ->
    _ = livery_h3:stop(?config(h3_listener, Config)),
    ok;
end_per_testcase(_TC, Config) ->
    _ = cowboy:stop_listener(?MODULE),
    _ = livery_h1:stop(?config(h1_listener, Config)),
    ok.

%% One Livery router-dispatch handler serving every migration route.
livery_handler() ->
    livery_example_migration:handler().

%%====================================================================
%% H1 parity: Cowboy vs Livery
%%====================================================================

plain_parity(Config) ->
    {C, L} = both(Config, <<"GET">>, <<"/plain">>, [], <<>>),
    assert_status(200, C, L),
    assert_header(<<"content-type">>, C, L),
    assert_body(C, L),
    ?assertEqual(<<"Hello world!">>, L#response.body).

things_list_parity(Config) ->
    {C, L} = both(Config, <<"GET">>, <<"/things">>, [], <<>>),
    assert_status(200, C, L),
    assert_header(<<"content-type">>, C, L),
    assert_body(C, L),
    ?assertEqual(<<"application/json">>, header(<<"content-type">>, L)).

things_create_parity(Config) ->
    Body = <<"{\"name\":\"x\"}">>,
    Hs = [{<<"content-type">>, <<"application/json">>}],
    {C, L} = both(Config, <<"POST">>, <<"/things">>, Hs, Body),
    assert_status(201, C, L),
    assert_header(<<"content-type">>, C, L),
    assert_header(<<"location">>, C, L),
    assert_body(C, L),
    %% Both servers read the request body and report its size.
    ?assertEqual(<<"/things/1">>, header(<<"location">>, L)),
    Expected = <<"{\"id\":1,\"received\":", (integer_to_binary(byte_size(Body)))/binary, "}">>,
    ?assertEqual(Expected, L#response.body).

thing_found_parity(Config) ->
    {C, L} = both(Config, <<"GET">>, <<"/things/1">>, [], <<>>),
    assert_status(200, C, L),
    assert_header(<<"content-type">>, C, L),
    assert_body(C, L).

thing_not_found_parity(Config) ->
    {C, L} = both(Config, <<"GET">>, <<"/things/2">>, [], <<>>),
    assert_status(404, C, L),
    assert_header(<<"content-type">>, C, L),
    assert_body(C, L).

things_method_not_allowed_parity(Config) ->
    {C, L} = both(Config, <<"PUT">>, <<"/things">>, [], <<>>),
    assert_status(405, C, L),
    assert_header(<<"content-type">>, C, L),
    assert_body(C, L),
    %% Allow is compared as a set (order is not significant).
    ?assertEqual(allow_set(C), allow_set(L)),
    ?assertEqual([<<"GET">>, <<"POST">>], allow_set(L)).

events_sse_parity(Config) ->
    {C, L} = both(Config, <<"GET">>, <<"/events">>, [], <<>>),
    assert_status(200, C, L),
    assert_header(<<"content-type">>, C, L),
    assert_header(<<"cache-control">>, C, L),
    assert_body(C, L),
    ?assertEqual(<<"text/event-stream">>, header(<<"content-type">>, L)),
    ?assertEqual(
        <<"event: tick\ndata: 1\n\nevent: tick\ndata: 2\n\nevent: tick\ndata: 3\n\n">>,
        L#response.body
    ).

stream_ndjson_parity(Config) ->
    {C, L} = both(Config, <<"GET">>, <<"/stream">>, [], <<>>),
    assert_status(200, C, L),
    assert_header(<<"content-type">>, C, L),
    assert_body(C, L),
    ?assertEqual(<<"application/x-ndjson">>, header(<<"content-type">>, L)),
    ?assertEqual(<<"{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n">>, L#response.body).

%%====================================================================
%% WebSocket parity (H1)
%%====================================================================

ws_echo_parity(Config) ->
    ?assertEqual({text, <<"ping">>}, ws_echo(?config(cowboy_port, Config))),
    ?assertEqual({text, <<"ping">>}, ws_echo(?config(livery_port, Config))).

%%====================================================================
%% H2/H3 unlock smoke (Livery only; Cowboy serves neither over H3)
%%====================================================================

plain_over_h2(Config) ->
    R = h2_get(?config(h2_port, Config), <<"/plain">>),
    ?assertEqual(200, R#response.status),
    ?assertEqual(<<"text/plain; charset=utf-8">>, header(<<"content-type">>, R)),
    ?assertEqual(<<"Hello world!">>, R#response.body).

stream_over_h2(Config) ->
    R = h2_get(?config(h2_port, Config), <<"/stream">>),
    ?assertEqual(200, R#response.status),
    ?assertEqual(<<"application/x-ndjson">>, header(<<"content-type">>, R)),
    ?assertEqual(<<"{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n">>, R#response.body).

plain_over_h3(Config) ->
    R = h3_get(?config(h3_port, Config), <<"/plain">>),
    ?assertEqual(200, R#response.status),
    ?assertEqual(<<"text/plain; charset=utf-8">>, header(<<"content-type">>, R)),
    ?assertEqual(<<"Hello world!">>, R#response.body).

%%====================================================================
%% Helpers: drive + assert
%%====================================================================

%% Drive the same request to Cowboy and Livery over H1.
both(Config, Method, Path, Headers, Body) ->
    C = http(?config(cowboy_port, Config), Method, Path, Headers, Body),
    L = http(?config(livery_port, Config), Method, Path, Headers, Body),
    {C, L}.

http(Port, Method, Path, Headers, Body) ->
    Url = iolist_to_binary([
        <<"http://127.0.0.1:">>, integer_to_binary(Port), Path
    ]),
    {ok, Status, RespHeaders, RespBody} = hackney:request(
        Method, Url, Headers, Body, [with_body, {recv_timeout, 15000}]
    ),
    #response{
        status = Status,
        headers = normalize_headers(RespHeaders),
        body = RespBody
    }.

assert_status(Expected, C, L) ->
    ?assertEqual(Expected, C#response.status),
    ?assertEqual(Expected, L#response.status).

assert_body(C, L) ->
    ?assertEqual(C#response.body, L#response.body).

assert_header(Name, C, L) ->
    ?assertEqual(header(Name, C), header(Name, L)).

header(Name, #response{headers = Hs}) ->
    case lists:keyfind(Name, 1, Hs) of
        {_, V} -> V;
        false -> undefined
    end.

allow_set(Resp) ->
    case header(<<"allow">>, Resp) of
        undefined ->
            undefined;
        V ->
            lists:sort([trim(M) || M <- binary:split(V, <<",">>, [global])])
    end.

trim(B) ->
    string:trim(B).

normalize_headers(Headers) ->
    [{string:lowercase(to_bin(N)), to_bin(V)} || {N, V} <- Headers].

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).

%%====================================================================
%% Helpers: WebSocket
%%====================================================================

ws_echo(Port) ->
    Url = iolist_to_binary([
        <<"ws://127.0.0.1:">>, integer_to_binary(Port), <<"/ws">>
    ]),
    Self = self(),
    {ok, Sess} = ws_client:connect(Url, #{
        handler => livery_ws_client_capture,
        handler_opts => #{parent => Self}
    }),
    try
        ok = ws:send(Sess, [{text, <<"ping">>}]),
        receive
            {captured, Frame} -> Frame
        after 15000 -> ct:fail(no_ws_echo)
        end
    after
        catch ws:close(Sess, 1000, <<"bye">>),
        catch ws:stop(Sess)
    end.

%%====================================================================
%% Helpers: H2 / H3 clients (GET only)
%%====================================================================

h2_get(Port, Path) ->
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    try
        {ok, StreamId} = h2:request(
            Conn, <<"GET">>, Path, [{<<"host">>, <<"127.0.0.1">>}]
        ),
        collect_h2(Conn, StreamId, undefined, [], [])
    after
        h2:close(Conn)
    end.

collect_h2(Conn, StreamId, Status, Headers, BodyAcc) ->
    receive
        {h2, Conn, {response, StreamId, S, Hs}} ->
            collect_h2(Conn, StreamId, S, Hs, BodyAcc);
        {h2, Conn, {data, StreamId, Chunk, false}} ->
            collect_h2(Conn, StreamId, Status, Headers, [Chunk | BodyAcc]);
        {h2, Conn, {data, StreamId, Chunk, true}} ->
            #response{
                status = Status,
                headers = normalize_headers(Headers),
                body = iolist_to_binary(lists:reverse([Chunk | BodyAcc]))
            };
        {h2, Conn, _Other} ->
            collect_h2(Conn, StreamId, Status, Headers, BodyAcc)
    after 15000 ->
        ct:fail(h2_timeout)
    end.

h3_get(Port, Path) ->
    {ok, Conn} = quic_h3:connect(
        <<"localhost">>, Port, #{verify => verify_none, sync => true}
    ),
    try
        {ok, StreamId} = quic_h3:request(
            Conn,
            [
                {<<":method">>, <<"GET">>},
                {<<":path">>, Path},
                {<<":scheme">>, <<"https">>},
                {<<":authority">>, <<"localhost">>}
            ],
            #{end_stream => true}
        ),
        collect_h3(Conn, StreamId, undefined, [], [])
    after
        catch quic_h3:close(Conn)
    end.

collect_h3(Conn, StreamId, Status, Headers, BodyAcc) ->
    receive
        {quic_h3, Conn, {response, StreamId, S, Hs}} ->
            collect_h3(Conn, StreamId, S, Hs, BodyAcc);
        {quic_h3, Conn, {data, StreamId, Chunk, false}} ->
            collect_h3(Conn, StreamId, Status, Headers, [Chunk | BodyAcc]);
        {quic_h3, Conn, {data, StreamId, Chunk, true}} ->
            #response{
                status = Status,
                headers = normalize_headers(Headers),
                body = iolist_to_binary(lists:reverse([Chunk | BodyAcc]))
            };
        {quic_h3, Conn, {stream_end, StreamId}} ->
            #response{
                status = Status,
                headers = normalize_headers(Headers),
                body = iolist_to_binary(lists:reverse(BodyAcc))
            };
        {quic_h3, Conn, _Other} ->
            collect_h3(Conn, StreamId, Status, Headers, BodyAcc)
    after 15000 ->
        ct:fail(h3_timeout)
    end.
