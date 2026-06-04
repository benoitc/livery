%% @doc Drives livery_client's balance layer against real loopback Livery
%% servers (real hackney, no external network), plus store unit tests.
-module(livery_client_balance_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    spreads_load/1,
    fails_over_past_dead/1,
    ejects_on_5xx/1,
    half_open_recovers/1,
    remove_endpoint_sticks/1,
    store_p2c_least_loaded/1,
    store_round_robin/1,
    store_eject_lifecycle/1,
    store_single_probe/1
]).

all() ->
    [
        spreads_load,
        fails_over_past_dead,
        ejects_on_5xx,
        half_open_recovers,
        remove_endpoint_sticks,
        store_p2c_least_loaded,
        store_round_robin,
        store_eject_lifecycle,
        store_single_probe
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(hackney),
    A = start_replica(a),
    B = start_replica(b),
    C = start_replica(c),
    [{a, A}, {b, B}, {c, C} | Config].

end_per_suite(Config) ->
    lists:foreach(
        fun(Key) -> livery:stop_service(maps:get(pid, ?config(Key, Config))) end,
        [a, b, c]
    ),
    ok.

%% Start one loopback replica tagged with its id, returning its base URL,
%% pid, and shared failure counter.
start_replica(Id) ->
    Counter = atomics:new(1, [{signed, false}]),
    Router = livery_router:compile([
        {<<"GET">>, <<"/id">>, fun handle_id/1},
        {<<"GET">>, <<"/flaky">>, fun handle_flaky/1},
        {<<"GET">>, <<"/down">>, fun handle_down/1}
    ]),
    {ok, Pid} = livery:start_service(#{
        http => #{port => 0},
        config => #{id => Id, counter => Counter},
        router => Router
    }),
    true = unlink(Pid),
    Port = maps:get(h1, livery:which_listeners(Pid)),
    Base = iolist_to_binary([<<"http://127.0.0.1:">>, integer_to_binary(Port)]),
    #{pid => Pid, base => Base, counter => Counter}.

%%====================================================================
%% Handlers
%%====================================================================

handle_id(Req) ->
    livery_resp:text(200, atom_to_binary(livery_req:config(id, Req), utf8)).

%% Fail the first two calls with 503, then succeed.
handle_flaky(Req) ->
    Ref = livery_req:config(counter, Req),
    case atomics:add_get(Ref, 1, 1) of
        N when N =< 2 -> livery_resp:text(503, <<"busy">>);
        _ -> livery_resp:text(200, <<"ok">>)
    end.

handle_down(_Req) -> livery_resp:text(503, <<"down">>).

%%====================================================================
%% Integration cases
%%====================================================================

spreads_load(Config) ->
    Client = balance_client(spread_pool, [base(a, Config), base(b, Config)], #{
        policy => round_robin
    }),
    Bodies = [body_of(Client, <<"/id">>) || _ <- lists:seq(1, 6)],
    ?assert(lists:member(<<"a">>, Bodies)),
    ?assert(lists:member(<<"b">>, Bodies)).

fails_over_past_dead(Config) ->
    Client = livery_client:new(#{
        stack => [
            livery_client:retry(#{max => 3}),
            livery_client:balance(#{
                name => failover_pool,
                endpoints => [dead_base(), base(a, Config)],
                policy => round_robin,
                eject_after => 2
            })
        ]
    }),
    {ok, Resp} = livery_client:get(Client, <<"/id">>),
    ?assertEqual(200, livery_client:status(Resp)),
    ?assertEqual({full, <<"a">>}, livery_client:body(Resp)).

ejects_on_5xx(Config) ->
    Client = balance_client(eject_pool, [base(a, Config)], #{
        eject_after => 2, eject_for => 60000
    }),
    %% A 503 is a valid response the caller still sees, but it counts as a
    %% failure for health, so two of them eject the only endpoint.
    {ok, R1} = livery_client:get(Client, <<"/down">>),
    ?assertEqual(503, livery_client:status(R1)),
    {ok, R2} = livery_client:get(Client, <<"/down">>),
    ?assertEqual(503, livery_client:status(R2)),
    ?assertEqual({error, no_endpoint}, livery_client:get(Client, <<"/down">>)).

half_open_recovers(Config) ->
    atomics:put(maps:get(counter, ?config(c, Config)), 1, 0),
    Client = balance_client(recover_pool, [base(c, Config)], #{
        eject_after => 2, eject_for => 80
    }),
    %% Two 503s eject it; while ejected it fast-fails with no_endpoint.
    {ok, _} = livery_client:get(Client, <<"/flaky">>),
    {ok, _} = livery_client:get(Client, <<"/flaky">>),
    ?assertEqual({error, no_endpoint}, livery_client:get(Client, <<"/flaky">>)),
    %% After the cooldown one request is leased as a probe; the endpoint is
    %% healthy now, so it reinstates.
    timer:sleep(150),
    {ok, Resp} = livery_client:get(Client, <<"/flaky">>),
    ?assertEqual(200, livery_client:status(Resp)),
    ?assertEqual(200, livery_client:status(element(2, livery_client:get(Client, <<"/flaky">>)))).

remove_endpoint_sticks(Config) ->
    Client = balance_client(remove_pool, [base(a, Config), base(b, Config)], #{
        policy => round_robin
    }),
    %% Warm the pool, then drop b at runtime.
    _ = body_of(Client, <<"/id">>),
    ok = livery_client:remove_endpoint(remove_pool, base(b, Config)),
    Bodies = [body_of(Client, <<"/id">>) || _ <- lists:seq(1, 6)],
    %% A later request lazily re-ensures the pool, but create-once means b
    %% does not come back.
    ?assert(lists:member(<<"a">>, Bodies)),
    ?assertNot(lists:member(<<"b">>, Bodies)).

%%====================================================================
%% Store unit cases
%%====================================================================

store_p2c_least_loaded(_Config) ->
    Name = unique(p2c),
    ok = livery_client_balance_store:ensure(Name, [<<"u1">>, <<"u2">>]),
    %% First pick lands on either; the second must avoid the now-loaded one.
    {ok, Ep1, T1} = livery_client_balance_store:pick(Name, p2c, 1000),
    {ok, Ep2, T2} = livery_client_balance_store:pick(Name, p2c, 1000),
    ?assertNotEqual(Ep1, Ep2),
    livery_client_balance_store:release(T1),
    livery_client_balance_store:release(T2),
    livery_client_balance_store:reset(Name).

store_round_robin(_Config) ->
    Name = unique(rr),
    ok = livery_client_balance_store:ensure(Name, [<<"x">>, <<"y">>, <<"z">>]),
    Picks = [
        begin
            {ok, Ep, T} = livery_client_balance_store:pick(Name, round_robin, 1000),
            livery_client_balance_store:release(T),
            Ep
        end
     || _ <- lists:seq(1, 6)
    ],
    Counts = [length([E || E <- Picks, E =:= Ep]) || Ep <- [<<"x">>, <<"y">>, <<"z">>]],
    ?assertEqual([2, 2, 2], Counts),
    livery_client_balance_store:reset(Name).

store_eject_lifecycle(_Config) ->
    Name = unique(life),
    ok = livery_client_balance_store:ensure(Name, [<<"only">>]),
    ok = livery_client_balance_store:record(Name, <<"only">>, err, 2, 50),
    ok = livery_client_balance_store:record(Name, <<"only">>, err, 2, 50),
    ?assertEqual({error, no_endpoint}, livery_client_balance_store:pick(Name, p2c, 50)),
    timer:sleep(70),
    {ok, <<"only">>, T} = livery_client_balance_store:pick(Name, p2c, 50),
    livery_client_balance_store:release(T),
    ok = livery_client_balance_store:record(Name, <<"only">>, ok, 2, 50),
    {ok, <<"only">>, T2} = livery_client_balance_store:pick(Name, p2c, 50),
    livery_client_balance_store:release(T2),
    livery_client_balance_store:reset(Name).

store_single_probe(_Config) ->
    Name = unique(probe),
    ok = livery_client_balance_store:ensure(Name, [<<"one">>]),
    ok = livery_client_balance_store:record(Name, <<"one">>, err, 2, 50),
    ok = livery_client_balance_store:record(Name, <<"one">>, err, 2, 50),
    timer:sleep(70),
    Self = self(),
    [
        spawn(fun() ->
            Self ! {probe, livery_client_balance_store:pick(Name, p2c, 1000)}
        end)
     || _ <- lists:seq(1, 20)
    ],
    Results = [
        receive
            {probe, R} -> R
        after 5000 -> timeout
        end
     || _ <- lists:seq(1, 20)
    ],
    Wins = [R || {ok, _, _} = R <- Results],
    ?assertEqual(1, length(Wins)),
    livery_client_balance_store:reset(Name).

%%====================================================================
%% Helpers
%%====================================================================

balance_client(Name, Endpoints, Extra) ->
    Opts = maps:merge(#{name => Name, endpoints => Endpoints}, Extra),
    livery_client:new(#{stack => [livery_client:balance(Opts)]}).

body_of(Client, Path) ->
    {ok, Resp} = livery_client:get(Client, Path),
    {full, Body} = livery_client:body(Resp),
    Body.

base(Key, Config) -> maps:get(base, ?config(Key, Config)).

unique(Tag) -> {Tag, erlang:unique_integer()}.

%% A loopback port with nothing listening, so connects are refused.
dead_base() ->
    {ok, LSock} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(LSock),
    gen_tcp:close(LSock),
    iolist_to_binary([<<"http://127.0.0.1:">>, integer_to_binary(Port)]).
