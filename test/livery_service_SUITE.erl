%% @doc End-to-end smoke for `livery:start_service/1`.
%%
%% Brings up H1 on TCP, H2 on TLS, and H3 on UDP from a single
%% `livery:start_service/1` call sharing one handler and one
%% middleware stack, then hits each protocol with its own client
%% and asserts the same handler served the request. Also verifies
%% that Alt-Svc is injected on H1/H2 responses but not H3.
-module(livery_service_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    one_call_serves_all_three/1,
    alt_svc_advertised_on_h1_and_h2_only/1,
    which_listeners_reports_all_three/1,
    router_service_dispatches_routes/1,
    service_without_handler_or_router_fails/1,
    stop_accepting_refuses_new_connections/1,
    drain_lets_inflight_finish/1,
    drain_times_out_on_stuck_request/1
]).

%%====================================================================
%% Suite plumbing
%%====================================================================

all() ->
    [
        one_call_serves_all_three,
        alt_svc_advertised_on_h1_and_h2_only,
        which_listeners_reports_all_three,
        router_service_dispatches_routes,
        service_without_handler_or_router_fails,
        stop_accepting_refuses_new_connections,
        drain_lets_inflight_finish,
        drain_times_out_on_stuck_request
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(h1),
    {ok, _} = application:ensure_all_started(h2),
    {ok, _} = application:ensure_all_started(quic),
    {ok, _} = application:ensure_all_started(hackney),
    {ok, CertDer, KeyDer} = livery_test_certs:load(),
    {CertFile, KeyFile} = livery_test_certs:paths(),
    [
        {cert_der, CertDer},
        {key_der, KeyDer},
        {cert_file, CertFile},
        {key_file, KeyFile}
        | Config
    ].

end_per_suite(_Config) ->
    _ = application:stop(hackney),
    _ = application:stop(quic),
    _ = application:stop(h2),
    _ = application:stop(h1),
    _ = application:stop(livery),
    ok.

%%====================================================================
%% Cases
%%====================================================================

one_call_serves_all_three(Config) ->
    {ok, Pid} = start_full_service(Config),
    try
        Ports = livery:which_listeners(Pid),
        ?assertMatch(#{h1 := _, h2 := _, h3 := _}, Ports),
        ?assertEqual(<<"hello">>, body_via_h1(maps:get(h1, Ports))),
        ?assertEqual(<<"hello">>, body_via_h2(maps:get(h2, Ports))),
        ?assertEqual(<<"hello">>, body_via_h3(maps:get(h3, Ports), Config))
    after
        livery:stop_service(Pid)
    end.

alt_svc_advertised_on_h1_and_h2_only(Config) ->
    {ok, Pid} = start_full_service(Config),
    try
        Ports = livery:which_listeners(Pid),
        H3Port = maps:get(h3, Ports),
        Expected = iolist_to_binary([
            <<"h3=\":">>,
            integer_to_binary(H3Port),
            <<"\"; ma=86400">>
        ]),
        ?assertEqual(Expected, h1_header(maps:get(h1, Ports), <<"alt-svc">>)),
        ?assertEqual(Expected, h2_header(maps:get(h2, Ports), <<"alt-svc">>)),
        ?assertEqual(
            undefined,
            h3_header(maps:get(h3, Ports), Config, <<"alt-svc">>)
        )
    after
        livery:stop_service(Pid)
    end.

which_listeners_reports_all_three(Config) ->
    {ok, Pid} = start_full_service(Config),
    try
        Ports = livery:which_listeners(Pid),
        ?assertEqual(3, map_size(Ports)),
        lists:foreach(
            fun(K) ->
                ?assert(is_integer(maps:get(K, Ports)))
            end,
            [h1, h2, h3]
        )
    after
        livery:stop_service(Pid)
    end.

router_service_dispatches_routes(_Config) ->
    Router = livery_router:compile([
        {<<"GET">>, <<"/">>, fun(_R) -> livery_resp:text(200, <<"root">>) end},
        {<<"GET">>, <<"/hi/:name">>, fun(R) ->
            livery_resp:text(200, livery_req:binding(<<"name">>, R))
        end},
        {<<"POST">>, <<"/">>, fun(_R) -> livery_resp:text(201, <<"made">>) end}
    ]),
    {ok, Pid} = livery:start_service(#{http => #{port => 0}, router => Router}),
    try
        Port = maps:get(h1, livery:which_listeners(Pid)),
        ?assertEqual({200, <<"root">>}, http_get(Port, <<"/">>)),
        ?assertEqual({200, <<"ada">>}, http_get(Port, <<"/hi/ada">>)),
        %% unknown path -> 404
        {404, _} = http_get(Port, <<"/missing">>),
        %% wrong method on a known path -> 405
        {405, _} = http_delete(Port, <<"/">>)
    after
        livery:stop_service(Pid)
    end.

service_without_handler_or_router_fails(_Config) ->
    process_flag(trap_exit, true),
    ?assertMatch({error, _}, livery:start_service(#{http => #{port => 0}})),
    process_flag(trap_exit, false).

stop_accepting_refuses_new_connections(_Config) ->
    {ok, Pid} = livery:start_service(#{
        http => #{port => 0},
        handler => fun(_R) -> livery_resp:text(200, <<"ok">>) end
    }),
    Port = maps:get(h1, livery:which_listeners(Pid)),
    ?assertMatch({ok, 200, _, <<"ok">>}, http_try(Port, <<"/">>)),
    ok = livery_service:stop_accepting(Pid),
    ?assertMatch({error, _}, http_try(Port, <<"/">>)),
    livery:stop_service(Pid).

drain_lets_inflight_finish(_Config) ->
    Self = self(),
    Ref = make_ref(),
    Handler = fun(_R) ->
        Self ! {ready, Ref, self()},
        receive
            {release, Ref} -> ok
        end,
        livery_resp:text(200, <<"done">>)
    end,
    {ok, Pid} = livery:start_service(#{http => #{port => 0}, handler => Handler}),
    Port = maps:get(h1, livery:which_listeners(Pid)),
    spawn(fun() -> Self ! {client_done, http_get(Port, <<"/">>)} end),
    WPid =
        receive
            {ready, Ref, P} -> P
        after 5000 -> ct:fail(no_request)
        end,
    ?assertEqual(1, livery_drain:in_flight()),
    %% Drain in the background; release the in-flight request so it
    %% can finish during the drain window.
    spawn(fun() -> Self ! {drain_done, livery:drain(Pid, #{timeout => 5000})} end),
    WPid ! {release, Ref},
    ?assertEqual(
        {200, <<"done">>},
        receive
            {client_done, R} -> R
        after 5000 -> ct:fail(no_client)
        end
    ),
    ?assertEqual(
        ok,
        receive
            {drain_done, D} -> D
        after 6000 -> ct:fail(no_drain)
        end
    ),
    ?assertNot(is_process_alive(Pid)).

drain_times_out_on_stuck_request(_Config) ->
    Self = self(),
    Ref = make_ref(),
    Handler = fun(_R) ->
        Self ! {ready, Ref, self()},
        receive
        after infinity -> ok
        end
    end,
    {ok, Pid} = livery:start_service(#{http => #{port => 0}, handler => Handler}),
    Port = maps:get(h1, livery:which_listeners(Pid)),
    spawn(fun() -> catch http_get(Port, <<"/">>) end),
    WPid =
        receive
            {ready, Ref, P} -> P
        after 5000 -> ct:fail(no_request)
        end,
    ?assertEqual(
        {error, timeout},
        livery:drain(Pid, #{timeout => 300, poll_interval => 50})
    ),
    ?assertNot(is_process_alive(Pid)),
    %% Clean up the stuck worker so it does not pollute later tests.
    exit(WPid, kill).

%%====================================================================
%% Fixtures
%%====================================================================

start_full_service(Config) ->
    CertDer = ?config(cert_der, Config),
    KeyDer = ?config(key_der, Config),
    CertFile = ?config(cert_file, Config),
    KeyFile = ?config(key_file, Config),
    livery:start_service(#{
        host => <<"localhost">>,
        http => #{port => 0},
        https => #{
            port => 0,
            cert => CertFile,
            key => KeyFile,
            transport => ssl
        },
        http3 => #{port => 0, cert => CertDer, key => KeyDer},
        handler => fun(_R) -> livery_resp:text(200, <<"hello">>) end,
        alt_svc => advertise
    }).

%%====================================================================
%% Clients
%%====================================================================

http_get(Port, Path) ->
    http_req(<<"GET">>, Port, Path).

http_delete(Port, Path) ->
    http_req(<<"DELETE">>, Port, Path).

http_req(Method, Port, Path) ->
    Url = iolist_to_binary([
        <<"http://127.0.0.1:">>,
        integer_to_binary(Port),
        Path
    ]),
    {ok, Status, _Hs, Body} =
        hackney:request(
            Method,
            Url,
            [],
            <<>>,
            [with_body, {recv_timeout, 5000}]
        ),
    {Status, Body}.

%% Like http_get but returns the raw hackney result (no match) and
%% uses a fresh connection (pool disabled), so a closed listen socket
%% surfaces as {error, _}. `stop_accepting' keeps existing pooled
%% keep-alive connections alive, so the test must dial anew.
http_try(Port, Path) ->
    Url = iolist_to_binary([
        <<"http://127.0.0.1:">>,
        integer_to_binary(Port),
        Path
    ]),
    hackney:request(
        <<"GET">>,
        Url,
        [],
        <<>>,
        [
            with_body,
            {pool, false},
            {connect_timeout, 1000},
            {recv_timeout, 1000}
        ]
    ).

body_via_h1(Port) ->
    Url = url(<<"http">>, Port),
    {ok, 200, _, Body} = hackney:request(
        <<"GET">>,
        Url,
        [],
        <<>>,
        [with_body, {recv_timeout, 5000}]
    ),
    Body.

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
        collect_h2(Conn, StreamId, undefined, [], [])
    after
        h2:close(Conn)
    end.

body_via_h3(Port, _Config) ->
    {ok, Conn} = quic_h3:connect(
        <<"localhost">>,
        Port,
        #{verify => verify_none, sync => true}
    ),
    try
        {ok, StreamId} = quic_h3:request(
            Conn,
            [
                {<<":method">>, <<"GET">>},
                {<<":path">>, <<"/">>},
                {<<":scheme">>, <<"https">>},
                {<<":authority">>, <<"localhost">>}
            ],
            #{end_stream => true}
        ),
        collect_h3(Conn, StreamId, undefined, [], [])
    after
        catch quic_h3:close(Conn)
    end.

h1_header(Port, Name) ->
    Url = url(<<"http">>, Port),
    {ok, 200, Headers, _} = hackney:request(
        <<"GET">>,
        Url,
        [],
        <<>>,
        [with_body, {recv_timeout, 5000}]
    ),
    header(Name, Headers).

h2_header(Port, Name) ->
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
        case wait_h2_response(Conn, StreamId) of
            {Status, Headers} when Status =/= undefined ->
                header(Name, Headers);
            _ ->
                undefined
        end
    after
        h2:close(Conn)
    end.

h3_header(Port, _Config, Name) ->
    {ok, Conn} = quic_h3:connect(
        <<"localhost">>,
        Port,
        #{verify => verify_none, sync => true}
    ),
    try
        {ok, StreamId} = quic_h3:request(
            Conn,
            [
                {<<":method">>, <<"GET">>},
                {<<":path">>, <<"/">>},
                {<<":scheme">>, <<"https">>},
                {<<":authority">>, <<"localhost">>}
            ],
            #{end_stream => true}
        ),
        case wait_h3_response(Conn, StreamId) of
            {_Status, Headers} -> header(Name, Headers);
            _ -> undefined
        end
    after
        catch quic_h3:close(Conn)
    end.

%%====================================================================
%% Internals
%%====================================================================

url(Scheme, Port) ->
    iolist_to_binary([
        Scheme,
        <<"://127.0.0.1:">>,
        integer_to_binary(Port),
        <<"/">>
    ]).

collect_h2(Conn, StreamId, _Status, _Headers, BodyAcc) ->
    receive
        {h2, Conn, {response, StreamId, _S, _Hs}} ->
            collect_h2(Conn, StreamId, _S, _Hs, BodyAcc);
        {h2, Conn, {data, StreamId, Chunk, false}} ->
            collect_h2(Conn, StreamId, _Status, _Headers, [Chunk | BodyAcc]);
        {h2, Conn, {data, StreamId, Chunk, true}} ->
            iolist_to_binary(lists:reverse([Chunk | BodyAcc]));
        {h2, Conn, _Other} ->
            collect_h2(Conn, StreamId, _Status, _Headers, BodyAcc)
    after 5000 ->
        error(h2_timeout)
    end.

wait_h2_response(Conn, StreamId) ->
    receive
        {h2, Conn, {response, StreamId, S, Hs}} ->
            drain_h2(Conn, StreamId),
            {S, Hs};
        {h2, Conn, _Other} ->
            wait_h2_response(Conn, StreamId)
    after 5000 ->
        error(h2_timeout)
    end.

drain_h2(Conn, StreamId) ->
    receive
        {h2, Conn, {data, StreamId, _, true}} -> ok;
        {h2, Conn, _} -> drain_h2(Conn, StreamId)
    after 1000 -> ok
    end.

collect_h3(Conn, StreamId, _Status, _Headers, BodyAcc) ->
    receive
        {quic_h3, Conn, {response, StreamId, _S, _Hs}} ->
            collect_h3(Conn, StreamId, _S, _Hs, BodyAcc);
        {quic_h3, Conn, {data, StreamId, Chunk, false}} ->
            collect_h3(Conn, StreamId, _Status, _Headers, [Chunk | BodyAcc]);
        {quic_h3, Conn, {data, StreamId, Chunk, true}} ->
            iolist_to_binary(lists:reverse([Chunk | BodyAcc]));
        {quic_h3, Conn, {stream_end, StreamId}} ->
            iolist_to_binary(lists:reverse(BodyAcc));
        {quic_h3, Conn, _Other} ->
            collect_h3(Conn, StreamId, _Status, _Headers, BodyAcc)
    after 10000 ->
        error(h3_timeout)
    end.

wait_h3_response(Conn, StreamId) ->
    receive
        {quic_h3, Conn, {response, StreamId, S, Hs}} ->
            drain_h3(Conn, StreamId),
            {S, Hs};
        {quic_h3, Conn, _Other} ->
            wait_h3_response(Conn, StreamId)
    after 10000 ->
        error(h3_timeout)
    end.

drain_h3(Conn, StreamId) ->
    receive
        {quic_h3, Conn, {data, StreamId, _, true}} -> ok;
        {quic_h3, Conn, {stream_end, StreamId}} -> ok;
        {quic_h3, Conn, _} -> drain_h3(Conn, StreamId)
    after 1000 -> ok
    end.

header(Name, Headers) ->
    LName = string:lowercase(Name),
    case
        lists:keyfind(LName, 1, [
            {string:lowercase(N), V}
         || {N, V} <- Headers
        ])
    of
        {_, V} when is_binary(V) -> V;
        {_, V} when is_list(V) -> list_to_binary(V);
        false -> undefined
    end.
