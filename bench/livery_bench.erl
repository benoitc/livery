-module(livery_bench).
-moduledoc """
Latency/throughput benchmark harness for Livery.

Drives keep-alive load against a reference handler served by
`livery_h1`, `livery_h2` (h2c), or `livery_h3`, and reports request
count, throughput, and p50/p90/p99/max latency. `compare/2`
implements the >10% p99 regression gate from the rewrite plan.

Run it from a shell (interactively, not via `halt/0`, so the
listener tears down cleanly):

```
rebar3 as bench shell
1> livery_bench:run().                          %% H1, defaults
2> livery_bench:run(#{protocol => h2}).
3> livery_bench:run_all(#{connections => 100, duration_ms => 5000}).
```

`run/0,1` returns a metrics map; `run_all/0,1` returns
`[{Protocol, Metrics}]`. Persist a metrics map as a baseline and
pass it to `compare/2` to gate future runs.
""".

-export([run/0, run/1, run_all/0, run_all/1, compare/2, report/1]).
-export([profile/2]).

-define(RAW_REQUEST, <<"GET / HTTP/1.1\r\nHost: bench\r\n\r\n">>).

%% @doc Run H1 with defaults: 50 connections for 3 seconds.
run() ->
    run(#{}).

%% @doc Run the benchmark for one protocol. Options: `protocol'
%% (`h1' | `h2' | `h3', default `h1'), `connections', `duration_ms',
%% `warmup_ms', `port'.
run(Opts) ->
    Protocol = maps:get(protocol, Opts, h1),
    Conns = maps:get(connections, Opts, 50),
    Duration = maps:get(duration_ms, Opts, 3000),
    Warmup = maps:get(warmup_ms, Opts, 500),
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = ensure_started(Protocol),
    {ok, Listener} = start_listener(Protocol, Opts),
    try
        Port = listener_port(Protocol, Listener),
        %% warmup, discarded
        _ = drive(Protocol, Port, Conns, Warmup),
        {Lats, Count, Reconns} = drive(Protocol, Port, Conns, Duration),
        Metrics = metrics(Protocol, Lats, Count, Reconns, Duration, Conns),
        report(Metrics),
        Metrics
    after
        stop_listener(Protocol, Listener)
    end.

%% @doc Profile one protocol with fprof over `NReqs' sequential
%% requests on a single connection. Traces all processes (so the
%% wire library's own processes are included) and writes an fprof
%% report sorted by own time to `/tmp/livery_<protocol>.fprof'.
%% Returns the report path.
profile(Protocol, NReqs) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = ensure_started(Protocol),
    {ok, Listener} = start_listener(Protocol, #{}),
    try
        Port = listener_port(Protocol, Listener),
        {ok, Handle} = connect(Protocol, Port),
        Dest = "/tmp/livery_" ++ atom_to_list(Protocol) ++ ".fprof",
        fprof:trace([start, {procs, all}]),
        _ = [do_request(Protocol, Handle) || _ <- lists:seq(1, NReqs)],
        fprof:trace(stop),
        fprof:profile(),
        fprof:analyse([{dest, Dest}, {sort, own}, {cols, 120}, {totals, true}]),
        close(Protocol, Handle),
        {ok, Dest}
    after
        stop_listener(Protocol, Listener)
    end.

%% @doc Run the benchmark across H1, H2, and H3.
run_all() ->
    run_all(#{}).

run_all(Opts) ->
    [{P, run(Opts#{protocol => P})} || P <- [h1, h2, h3]].

%% @doc Compare a current run against a baseline. Fails when p99
%% regresses by more than 10%.
compare(Baseline, Current) ->
    B = maps:get(p99_us, Baseline),
    C = maps:get(p99_us, Current),
    Threshold = B * 1.10,
    case C =< Threshold of
        true ->
            {ok, #{baseline_p99_us => B, current_p99_us => C}};
        false ->
            {regressed, #{
                baseline_p99_us => B,
                current_p99_us => C,
                threshold_us => round(Threshold)
            }}
    end.

%% @doc Print a metrics map.
report(M) ->
    io:format(
        "~n=== livery_bench (~p) ===~n"
        "connections : ~p~n"
        "duration    : ~p ms~n"
        "requests    : ~p (~p reconnects)~n"
        "throughput  : ~.1f req/s~n"
        "latency p50 : ~.3f ms~n"
        "latency p90 : ~.3f ms~n"
        "latency p99 : ~.3f ms~n"
        "latency max : ~.3f ms~n~n",
        [
            maps:get(protocol, M),
            maps:get(connections, M),
            maps:get(duration_ms, M),
            maps:get(requests, M),
            maps:get(reconnects, M),
            maps:get(throughput_rps, M),
            maps:get(p50_us, M) / 1000,
            maps:get(p90_us, M) / 1000,
            maps:get(p99_us, M) / 1000,
            maps:get(max_us, M) / 1000
        ]
    ).

%%====================================================================
%% Listener lifecycle per protocol
%%====================================================================

ensure_started(h1) -> application:ensure_all_started(h1);
ensure_started(h2) -> application:ensure_all_started(h2);
ensure_started(h3) -> application:ensure_all_started(quic).

ref_handler() ->
    fun(_Req) -> livery_resp:json(200, <<"{\"ok\":true}">>) end.

start_listener(h1, Opts) ->
    livery_h1:start(#{
        port => maps:get(port, Opts, 0),
        stack => [],
        handler => ref_handler()
    });
start_listener(h2, Opts) ->
    livery_h2:start(#{
        port => maps:get(port, Opts, 0),
        transport => tcp,
        stack => [],
        handler => ref_handler()
    });
start_listener(h3, Opts) ->
    {Cert, Key} = load_certs(),
    livery_h3:start(#{
        port => maps:get(port, Opts, 0),
        cert => Cert,
        key => Key,
        stack => [],
        handler => ref_handler()
    }).

listener_port(h1, L) ->
    h1:server_port(L);
listener_port(h2, L) ->
    h2:server_port(L);
listener_port(h3, L) ->
    {ok, P} = quic:get_server_port(L),
    P.

stop_listener(h1, L) -> livery_h1:stop(L);
stop_listener(h2, L) -> livery_h2:stop(L);
stop_listener(h3, L) -> livery_h3:stop(L).

%% Reuse the vendored self-signed test certs for the H3 listener.
load_certs() ->
    Base = code:lib_dir(livery),
    Dir = filename:join([Base, "..", "..", "..", "..", "test", "certs"]),
    {ok, CertPem} = file:read_file(filename:join(Dir, "cert.pem")),
    {ok, KeyPem} = file:read_file(filename:join(Dir, "key.pem")),
    [{'Certificate', CertDer, _}] = public_key:pem_decode(CertPem),
    [{KeyType, KeyDer, _} | _] = public_key:pem_decode(KeyPem),
    {CertDer, public_key:der_decode(KeyType, KeyDer)}.

%%====================================================================
%% Load driver
%%====================================================================

drive(Protocol, Port, Conns, Duration) ->
    Parent = self(),
    Deadline = erlang:monotonic_time(millisecond) + Duration,
    Pids = [
        spawn_link(fun() -> worker(Parent, Protocol, Port, Deadline) end)
     || _ <- lists:seq(1, Conns)
    ],
    collect(Pids, [], 0, 0).

collect([], Lats, Count, Reconns) ->
    {Lats, Count, Reconns};
collect([Pid | Rest], Lats, Count, Reconns) ->
    receive
        {done, Pid, Acc} ->
            collect(
                Rest,
                maps:get(lats, Acc) ++ Lats,
                Count + maps:get(count, Acc),
                Reconns + maps:get(reconns, Acc)
            )
    end.

worker(Parent, Protocol, Port, Deadline) ->
    case connect(Protocol, Port) of
        {ok, Handle} ->
            Acc = loop(
                Protocol,
                Port,
                Handle,
                Deadline,
                #{lats => [], count => 0, reconns => 0}
            ),
            Parent ! {done, self(), Acc};
        {error, _} ->
            Parent ! {done, self(), #{lats => [], count => 0, reconns => 1}}
    end.

%% On a request error (e.g. an HTTP/2 connection hitting its
%% per-connection stream limit) reconnect and keep going; count the
%% reconnect separately rather than aborting the worker.
loop(Protocol, Port, Handle, Deadline, Acc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true ->
            close(Protocol, Handle),
            Acc;
        false ->
            Start = erlang:monotonic_time(microsecond),
            case do_request(Protocol, Handle) of
                ok ->
                    Lat = erlang:monotonic_time(microsecond) - Start,
                    loop(Protocol, Port, Handle, Deadline, Acc#{
                        lats := [Lat | maps:get(lats, Acc)],
                        count := maps:get(count, Acc) + 1
                    });
                {error, _} ->
                    close(Protocol, Handle),
                    Acc1 = Acc#{reconns := maps:get(reconns, Acc) + 1},
                    case connect(Protocol, Port) of
                        {ok, Handle2} ->
                            loop(Protocol, Port, Handle2, Deadline, Acc1);
                        {error, _} ->
                            Acc1
                    end
            end
    end.

%%====================================================================
%% Per-protocol client
%%====================================================================

connect(h1, Port) ->
    gen_tcp:connect(
        "127.0.0.1",
        Port,
        [binary, {active, false}, {packet, raw}, {nodelay, true}],
        5000
    );
connect(h2, Port) ->
    case h2:connect("127.0.0.1", Port, #{transport => tcp}) of
        {ok, Conn} ->
            %% h2:connect returns before the preface/SETTINGS exchange
            %% finishes; wait for the readiness signal so the first
            %% request is not raced under concurrent connects.
            receive
                {h2, Conn, connected} -> ok
            after 5000 -> ok
            end,
            {ok, Conn};
        Error ->
            Error
    end;
connect(h3, Port) ->
    quic_h3:connect(<<"localhost">>, Port, #{verify => verify_none, sync => true}).

close(h1, Sock) ->
    gen_tcp:close(Sock);
close(h2, Conn) ->
    h2:close(Conn);
close(h3, Conn) ->
    catch quic_h3:close(Conn),
    ok.

do_request(h1, Sock) ->
    case gen_tcp:send(Sock, ?RAW_REQUEST) of
        ok -> read_response(Sock, <<>>);
        Error -> Error
    end;
do_request(h2, Conn) ->
    case h2:request(Conn, <<"GET">>, <<"/">>, [{<<"host">>, <<"bench">>}]) of
        {ok, StreamId} -> await_h2(Conn, StreamId);
        Error -> Error
    end;
do_request(h3, Conn) ->
    Headers = [
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>},
        {<<":scheme">>, <<"https">>},
        {<<":authority">>, <<"localhost">>}
    ],
    case quic_h3:request(Conn, Headers, #{end_stream => true}) of
        {ok, StreamId} -> await_h3(Conn, StreamId);
        Error -> Error
    end.

await_h2(Conn, StreamId) ->
    receive
        {h2, Conn, {data, StreamId, _, true}} -> ok;
        {h2, Conn, {trailers, StreamId, _}} -> ok;
        {h2, Conn, {data, StreamId, _, false}} -> await_h2(Conn, StreamId);
        {h2, Conn, {response, StreamId, _, _}} -> await_h2(Conn, StreamId);
        {h2, Conn, _Other} -> await_h2(Conn, StreamId)
    after 5000 ->
        {error, timeout}
    end.

await_h3(Conn, StreamId) ->
    receive
        {quic_h3, Conn, {data, StreamId, _, true}} -> ok;
        {quic_h3, Conn, {stream_end, StreamId}} -> ok;
        {quic_h3, Conn, {trailers, StreamId, _}} -> ok;
        {quic_h3, Conn, {data, StreamId, _, false}} -> await_h3(Conn, StreamId);
        {quic_h3, Conn, {response, StreamId, _, _}} -> await_h3(Conn, StreamId);
        {quic_h3, Conn, _Other} -> await_h3(Conn, StreamId)
    after 5000 ->
        {error, timeout}
    end.

%% H1: read headers, then exactly Content-Length body bytes (keep-alive).
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

read_body(_Sock, Body, Len) when byte_size(Body) >= Len ->
    ok;
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
            Tail = binary:part(
                Lower,
                Start + MLen,
                byte_size(Lower) - Start - MLen
            ),
            [Val | _] = binary:split(Tail, <<"\r\n">>),
            binary_to_integer(string:trim(Val))
    end.

%%====================================================================
%% Metrics
%%====================================================================

metrics(Protocol, Lats, Count, Reconns, Duration, Conns) ->
    Sorted = lists:sort(Lats),
    #{
        protocol => Protocol,
        connections => Conns,
        duration_ms => Duration,
        requests => Count,
        reconnects => Reconns,
        throughput_rps => Count * 1000 / Duration,
        p50_us => percentile(Sorted, 50),
        p90_us => percentile(Sorted, 90),
        p99_us => percentile(Sorted, 99),
        max_us =>
            case Sorted of
                [] -> 0;
                _ -> lists:last(Sorted)
            end
    }.

percentile([], _P) ->
    0;
percentile(Sorted, P) ->
    N = length(Sorted),
    Idx = max(1, min(N, round(P / 100 * N))),
    lists:nth(Idx, Sorted).
