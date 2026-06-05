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
-export([profile/2, sweep/3, compare_servers/0, compare_servers/1]).
-export([compare_servers_to_file/2, serve/3]).

-define(RAW_REQUEST, <<"GET / HTTP/1.1\r\nHost: bench\r\n\r\n">>).

%% @doc Run H1 with defaults: 50 connections for 3 seconds.
run() ->
    run(#{}).

%% @doc Run the benchmark for one protocol. Options: `protocol'
%% (`h1' | `h2' | `h3', default `h1'), `connections', `duration_ms',
%% `warmup_ms', `port'.
run(Opts) ->
    Protocol = maps:get(protocol, Opts, h1),
    Server = maps:get(server, Opts, livery),
    Conns = maps:get(connections, Opts, 50),
    Duration = maps:get(duration_ms, Opts, 3000),
    Warmup = maps:get(warmup_ms, Opts, 500),
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = ensure_started(Server, Protocol),
    {ok, Listener} = start_listener(Server, Protocol, Opts),
    try
        Port = listener_port(Server, Protocol, Listener),
        %% warmup, discarded
        _ = drive(Protocol, Port, Conns, Warmup),
        {Lats, Count, Reconns} = drive(Protocol, Port, Conns, Duration),
        Metrics0 = metrics(Protocol, Lats, Count, Reconns, Duration, Conns),
        Metrics = Metrics0#{server => Server},
        report(Metrics),
        Metrics
    after
        stop_listener(Server, Protocol, Listener)
    end.

%% @doc Profile one protocol with fprof over `NReqs' sequential
%% requests on a single connection. Traces all processes (so the
%% wire library's own processes are included) and writes an fprof
%% report sorted by own time to `/tmp/livery_<protocol>.fprof'.
%% Returns the report path.
profile(Protocol, NReqs) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = ensure_started(livery, Protocol),
    {ok, Listener} = start_listener(livery, Protocol, #{}),
    try
        Port = listener_port(livery, Protocol, Listener),
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
        stop_listener(livery, Protocol, Listener)
    end.

%% @doc Concurrency sweep: run `Protocol' at each connection count in
%% `ConnsList' for `DurationMs' and return
%% `[{Conns, ThroughputRps, P50Us, P99Us}]'. Use it to see whether
%% throughput scales with concurrency (CPU-bound) or plateaus early
%% (serialization bottleneck).
sweep(Protocol, ConnsList, DurationMs) ->
    [
        begin
            M = run(#{
                protocol => Protocol,
                connections => C,
                duration_ms => DurationMs,
                warmup_ms => 300
            }),
            {C, round(maps:get(throughput_rps, M)), maps:get(p50_us, M), maps:get(p99_us, M)}
        end
     || C <- ConnsList
    ].

%% @doc Run the benchmark across H1, H2, and H3.
run_all() ->
    run_all(#{}).

run_all(Opts) ->
    [{P, run(Opts#{protocol => P})} || P <- [h1, h2, h3]].

%% @doc Compare Livery against Cowboy on HTTP/1.1 and HTTP/2 (h2c)
%% with the same load driver and an identical JSON handler. Prints a
%% side-by-side table and returns the raw metrics maps.
compare_servers() ->
    compare_servers(#{}).

%% @doc Non-interactive entry point for `rebar3 ... --eval'. Runs the
%% comparison, writes the result (or any crash) to `File', and halts.
compare_servers_to_file(File, Opts) ->
    {ok, _} = application:ensure_all_started(livery),
    Out =
        try compare_servers(Opts) of
            R -> io_lib:format("~p~n", [R])
        catch
            C:E:S -> io_lib:format("CRASH ~p:~p~n~p~n", [C, E, S])
        end,
    ok = file:write_file(File, Out),
    ok.

compare_servers(Opts) ->
    Runs = [
        {Server, Protocol}
     || Protocol <- [h1, h2], Server <- [livery, cowboy]
    ],
    Results = [
        {Server, Protocol, run(Opts#{server => Server, protocol => Protocol})}
     || {Server, Protocol} <- Runs
    ],
    report_comparison(Results),
    Results.

report_comparison(Results) ->
    io:format(
        "~n=== livery vs cowboy ===~n"
        "~-8s ~-8s ~12s ~10s ~10s ~10s~n",
        ["server", "proto", "req/s", "p50 ms", "p90 ms", "p99 ms"]
    ),
    lists:foreach(
        fun({Server, Protocol, M}) ->
            io:format(
                "~-8s ~-8s ~12w ~10.3f ~10.3f ~10.3f~n",
                [
                    atom_to_list(Server),
                    atom_to_list(Protocol),
                    round(maps:get(throughput_rps, M)),
                    maps:get(p50_us, M) / 1000,
                    maps:get(p90_us, M) / 1000,
                    maps:get(p99_us, M) / 1000
                ]
            )
        end,
        Results
    ),
    io:nl().

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
        "~n=== livery_bench (~p / ~p) ===~n"
        "connections : ~p~n"
        "duration    : ~p ms~n"
        "requests    : ~p (~p reconnects)~n"
        "throughput  : ~.1f req/s~n"
        "latency p50 : ~.3f ms~n"
        "latency p90 : ~.3f ms~n"
        "latency p99 : ~.3f ms~n"
        "latency max : ~.3f ms~n~n",
        [
            maps:get(server, M, livery),
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

%% @doc Start a reference listener on a fixed port and block forever, so
%% an external load tool (wrk) can drive it out of process. `Server' is
%% `livery' or `cowboy'. Launch it under its own BEAM and kill that BEAM
%% to stop; this never returns. Used by `bench/compare.sh'.
serve(Server, Protocol, Port) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = ensure_started(Server, Protocol),
    {ok, _Listener} = start_listener(Server, Protocol, #{port => Port}),
    io:format("READY ~p ~p ~p~n", [Server, Protocol, Port]),
    receive
        stop -> ok
    end.

%%====================================================================
%% Listener lifecycle per protocol
%%====================================================================

ensure_started(livery, h1) -> application:ensure_all_started(h1);
ensure_started(livery, h2) -> application:ensure_all_started(h2);
ensure_started(livery, h3) -> application:ensure_all_started(quic);
ensure_started(cowboy, _Protocol) -> application:ensure_all_started(cowboy).

ref_handler() ->
    fun(_Req) -> livery_resp:json(200, <<"{\"ok\":true}">>) end.

start_listener(livery, h1, Opts) ->
    livery_h1:start(#{
        port => maps:get(port, Opts, 0),
        stack => [],
        handler => ref_handler()
    });
start_listener(livery, h2, Opts) ->
    livery_h2:start(#{
        port => maps:get(port, Opts, 0),
        transport => tcp,
        stack => [],
        handler => ref_handler()
    });
start_listener(livery, h3, Opts) ->
    {Cert, Key} = load_certs(),
    livery_h3:start(#{
        port => maps:get(port, Opts, 0),
        cert => Cert,
        key => Key,
        stack => [],
        handler => ref_handler(),
        pool_size => maps:get(pool_size, Opts, 1)
    });
%% Cowboy serves the same handler over a cleartext listener. The clear
%% listener speaks HTTP/1.1 and h2c (prior knowledge), so one listener
%% covers the h1 and h2 clients; restrict `protocols' so each run
%% exercises exactly the protocol under test.
start_listener(cowboy, Protocol, Opts) when Protocol =:= h1; Protocol =:= h2 ->
    Ref = cowboy_ref(Protocol),
    Dispatch = cowboy_router:compile([{'_', [{"/", bench_cowboy_h, []}]}]),
    Protocols =
        case Protocol of
            h1 -> [http];
            h2 -> [http2]
        end,
    {ok, _} = cowboy:start_clear(
        Ref,
        [{port, maps:get(port, Opts, 0)}],
        #{env => #{dispatch => Dispatch}, protocols => Protocols}
    ),
    {ok, Ref}.

listener_port(livery, h1, L) ->
    h1:server_port(L);
listener_port(livery, h2, L) ->
    h2:server_port(L);
listener_port(livery, h3, L) ->
    {ok, P} = quic:get_server_port(L),
    P;
listener_port(cowboy, _Protocol, Ref) ->
    ranch:get_port(Ref).

stop_listener(livery, h1, L) -> livery_h1:stop(L);
stop_listener(livery, h2, L) -> livery_h2:stop(L);
stop_listener(livery, h3, L) -> livery_h3:stop(L);
stop_listener(cowboy, _Protocol, Ref) -> cowboy:stop_listener(Ref).

cowboy_ref(h1) -> bench_cowboy_h1;
cowboy_ref(h2) -> bench_cowboy_h2.

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

%% H1: read one full response and keep the connection alive. The body is
%% framed either by Content-Length or by chunked transfer-encoding (livery
%% chunk-frames full bodies over H1); handle both so the next keep-alive
%% request starts from a clean buffer.
read_response(Sock, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Headers, Rest] ->
            case is_chunked(Headers) of
                true -> read_chunked(Sock, Rest);
                false -> read_body(Sock, Rest, content_length(Headers))
            end;
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

%% Read chunks until the terminating zero-length chunk ("0\r\n\r\n").
read_chunked(Sock, Buf) ->
    case binary:match(Buf, <<"0\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> read_chunked(Sock, <<Buf/binary, Data/binary>>);
                {error, _} = E -> E
            end;
        _ ->
            ok
    end.

is_chunked(Headers) ->
    binary:match(string:lowercase(Headers), <<"transfer-encoding: chunked">>) =/= nomatch.

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
