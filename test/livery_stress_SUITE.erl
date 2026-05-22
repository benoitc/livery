%% @doc Stress suite: hammer the H1 adapter with concurrent load and
%% assert stability invariants rather than performance. The key
%% property is that the per-request-worker model does not leak: after
%% the load drains, `livery_drain:in_flight/0' returns to 0 and the
%% service still answers. Bounded so it is safe to run in CI; the
%% `bench/' harness covers heavy, long-running load.
-module(livery_stress_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([sustained_concurrency_no_leak/1, connection_churn_no_leak/1]).

all() ->
    [sustained_concurrency_no_leak, connection_churn_no_leak].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(h1),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    {ok, Listener} = livery_h1:start(#{
        port => 0,
        stack => [],
        handler => fun(_Req) -> livery_resp:text(200, <<"ok">>) end
    }),
    Port = h1:server_port(Listener),
    [{listener, Listener}, {port, Port} | Config].

end_per_testcase(_TC, Config) ->
    catch livery_h1:stop(?config(listener, Config)),
    ok.

%%====================================================================
%% Cases
%%====================================================================

%% 64 connections, each firing 40 keep-alive requests (2560 total).
sustained_concurrency_no_leak(Config) ->
    Port = ?config(port, Config),
    Conns = 64,
    PerConn = 40,
    {Ok, Err} = run_load(fun() -> keepalive_worker(Port, PerConn) end, Conns),
    ?assertEqual(0, Err),
    ?assertEqual(Conns * PerConn, Ok),
    assert_drained(),
    ?assert(responsive(Port)).

%% 30 workers, each opening 10 fresh connections (300 connect/close
%% cycles) to stress setup and teardown rather than steady traffic.
connection_churn_no_leak(Config) ->
    Port = ?config(port, Config),
    Workers = 30,
    PerWorker = 10,
    {Ok, Err} = run_load(fun() -> churn_worker(Port, PerWorker) end, Workers),
    ?assertEqual(0, Err),
    ?assertEqual(Workers * PerWorker, Ok),
    assert_drained(),
    ?assert(responsive(Port)).

%%====================================================================
%% Load drivers
%%====================================================================

run_load(WorkerFun, N) ->
    Parent = self(),
    Pids = [
        spawn_link(fun() -> Parent ! {self(), WorkerFun()} end)
     || _ <- lists:seq(1, N)
    ],
    lists:foldl(
        fun(Pid, {AOk, AErr}) ->
            receive
                {Pid, {Ok, Err}} -> {AOk + Ok, AErr + Err}
            end
        end,
        {0, 0},
        Pids
    ).

%% One connection, many sequential keep-alive requests.
keepalive_worker(Port, N) ->
    case connect(Port) of
        {ok, Sock} ->
            R = lists:foldl(
                fun(_, {Ok, Err}) ->
                    case request(Sock) of
                        ok -> {Ok + 1, Err};
                        _ -> {Ok, Err + 1}
                    end
                end,
                {0, 0},
                lists:seq(1, N)
            ),
            gen_tcp:close(Sock),
            R;
        {error, _} ->
            {0, N}
    end.

%% Many short-lived connections, one request each.
churn_worker(Port, N) ->
    lists:foldl(
        fun(_, {Ok, Err}) ->
            case connect(Port) of
                {ok, Sock} ->
                    Res = request(Sock),
                    gen_tcp:close(Sock),
                    case Res of
                        ok -> {Ok + 1, Err};
                        _ -> {Ok, Err + 1}
                    end;
                {error, _} ->
                    {Ok, Err + 1}
            end
        end,
        {0, 0},
        lists:seq(1, N)
    ).

%%====================================================================
%% Minimal HTTP/1.1 client
%%====================================================================

connect(Port) ->
    gen_tcp:connect(
        "127.0.0.1",
        Port,
        [binary, {active, false}, {packet, raw}, {nodelay, true}],
        5000
    ).

request(Sock) ->
    case gen_tcp:send(Sock, <<"GET / HTTP/1.1\r\nHost: stress\r\n\r\n">>) of
        ok -> read_response(Sock, <<>>);
        Error -> Error
    end.

read_response(Sock, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Headers, Rest] ->
            read_body(Sock, Rest, content_length(Headers));
        [_] ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> read_response(Sock, <<Buf/binary, Data/binary>>);
                {error, _} = E -> E
            end
    end.

read_body(_Sock, Body, Len) when byte_size(Body) >= Len -> ok;
read_body(Sock, Body, Len) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> read_body(Sock, <<Body/binary, Data/binary>>, Len);
        {error, _} = E -> E
    end.

content_length(Headers) ->
    Lower = string:lowercase(Headers),
    case binary:match(Lower, <<"content-length:">>) of
        nomatch ->
            0;
        {Start, MLen} ->
            Tail = binary:part(Lower, Start + MLen, byte_size(Lower) - Start - MLen),
            [Val | _] = binary:split(Tail, <<"\r\n">>),
            binary_to_integer(string:trim(Val))
    end.

%%====================================================================
%% Invariants
%%====================================================================

%% Poll until no request workers remain (no leak), or fail after 5s.
assert_drained() ->
    assert_drained(50).

assert_drained(0) ->
    ?assertEqual(0, livery_drain:in_flight());
assert_drained(N) ->
    case livery_drain:in_flight() of
        0 ->
            ok;
        _ ->
            timer:sleep(100),
            assert_drained(N - 1)
    end.

responsive(Port) ->
    case connect(Port) of
        {ok, Sock} ->
            Res = request(Sock),
            gen_tcp:close(Sock),
            Res =:= ok;
        _ ->
            false
    end.
