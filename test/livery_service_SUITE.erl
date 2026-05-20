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
    which_listeners_reports_all_three/1
]).

%%====================================================================
%% Suite plumbing
%%====================================================================

all() ->
    [one_call_serves_all_three,
     alt_svc_advertised_on_h1_and_h2_only,
     which_listeners_reports_all_three].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(h1),
    {ok, _} = application:ensure_all_started(h2),
    {ok, _} = application:ensure_all_started(quic),
    {ok, _} = application:ensure_all_started(hackney),
    {ok, CertDer, KeyDer} = livery_test_certs:load(),
    {CertFile, KeyFile} = livery_test_certs:paths(),
    [{cert_der, CertDer}, {key_der, KeyDer},
     {cert_file, CertFile}, {key_file, KeyFile} | Config].

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
        Expected = iolist_to_binary([<<"h3=\":">>,
                                     integer_to_binary(H3Port),
                                     <<"\"; ma=86400">>]),
        ?assertEqual(Expected, h1_header(maps:get(h1, Ports), <<"alt-svc">>)),
        ?assertEqual(Expected, h2_header(maps:get(h2, Ports), <<"alt-svc">>)),
        ?assertEqual(undefined,
                     h3_header(maps:get(h3, Ports), Config, <<"alt-svc">>))
    after
        livery:stop_service(Pid)
    end.

which_listeners_reports_all_three(Config) ->
    {ok, Pid} = start_full_service(Config),
    try
        Ports = livery:which_listeners(Pid),
        ?assertEqual(3, map_size(Ports)),
        lists:foreach(fun(K) ->
            ?assert(is_integer(maps:get(K, Ports)))
        end, [h1, h2, h3])
    after
        livery:stop_service(Pid)
    end.

%%====================================================================
%% Fixtures
%%====================================================================

start_full_service(Config) ->
    CertDer  = ?config(cert_der, Config),
    KeyDer   = ?config(key_der, Config),
    CertFile = ?config(cert_file, Config),
    KeyFile  = ?config(key_file, Config),
    livery:start_service(#{
        host       => <<"localhost">>,
        http       => #{port => 0},
        https      => #{port => 0,
                        cert => CertFile, key => KeyFile,
                        transport => ssl},
        http3      => #{port => 0, cert => CertDer, key => KeyDer},
        handler    => fun(_R) -> livery_resp:text(200, <<"hello">>) end,
        alt_svc    => advertise
    }).

%%====================================================================
%% Clients
%%====================================================================

body_via_h1(Port) ->
    Url = url(<<"http">>, Port),
    {ok, 200, _, Body} = hackney:request(<<"GET">>, Url, [], <<>>,
                                          [with_body, {recv_timeout, 5000}]),
    Body.

body_via_h2(Port) ->
    {ok, Conn} = h2:connect("127.0.0.1", Port,
                            #{transport => ssl,
                              ssl_opts => [{verify, verify_none},
                                           {server_name_indication, "localhost"}]}),
    try
        {ok, StreamId} = h2:request(Conn, <<"GET">>, <<"/">>,
                                    [{<<"host">>, <<"localhost">>}]),
        collect_h2(Conn, StreamId, undefined, [], [])
    after
        h2:close(Conn)
    end.

body_via_h3(Port, _Config) ->
    {ok, Conn} = quic_h3:connect(<<"localhost">>, Port,
                                  #{verify => verify_none, sync => true}),
    try
        {ok, StreamId} = quic_h3:request(Conn, [
            {<<":method">>, <<"GET">>},
            {<<":path">>, <<"/">>},
            {<<":scheme">>, <<"https">>},
            {<<":authority">>, <<"localhost">>}
        ], #{end_stream => true}),
        collect_h3(Conn, StreamId, undefined, [], [])
    after
        catch quic_h3:close(Conn)
    end.

h1_header(Port, Name) ->
    Url = url(<<"http">>, Port),
    {ok, 200, Headers, _} = hackney:request(<<"GET">>, Url, [], <<>>,
                                             [with_body, {recv_timeout, 5000}]),
    header(Name, Headers).

h2_header(Port, Name) ->
    {ok, Conn} = h2:connect("127.0.0.1", Port,
                            #{transport => ssl,
                              ssl_opts => [{verify, verify_none},
                                           {server_name_indication, "localhost"}]}),
    try
        {ok, StreamId} = h2:request(Conn, <<"GET">>, <<"/">>,
                                    [{<<"host">>, <<"localhost">>}]),
        case wait_h2_response(Conn, StreamId) of
            {Status, Headers} when Status =/= undefined ->
                header(Name, Headers);
            _ -> undefined
        end
    after
        h2:close(Conn)
    end.

h3_header(Port, _Config, Name) ->
    {ok, Conn} = quic_h3:connect(<<"localhost">>, Port,
                                  #{verify => verify_none, sync => true}),
    try
        {ok, StreamId} = quic_h3:request(Conn, [
            {<<":method">>, <<"GET">>},
            {<<":path">>, <<"/">>},
            {<<":scheme">>, <<"https">>},
            {<<":authority">>, <<"localhost">>}
        ], #{end_stream => true}),
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
    iolist_to_binary([Scheme, <<"://127.0.0.1:">>,
                      integer_to_binary(Port), <<"/">>]).

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
    case lists:keyfind(LName, 1, [{string:lowercase(N), V}
                                  || {N, V} <- Headers]) of
        {_, V} when is_binary(V) -> V;
        {_, V} when is_list(V)   -> list_to_binary(V);
        false                    -> undefined
    end.
