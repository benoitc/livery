%% @doc Drives livery_client against a real loopback Livery server (real
%% hackney over the loopback, no external network), exercising each layer.
-module(livery_client_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    get_round_trip/1,
    post_round_trip/1,
    timeout_layer/1,
    retry_layer/1,
    concurrency_layer/1,
    circuit_layer/1,
    circuit_store_recovers/1,
    stream_response/1,
    stream_request/1,
    custom_adapter/1,
    no_content_response/1,
    head_request/1
]).

all() ->
    [
        get_round_trip,
        post_round_trip,
        timeout_layer,
        retry_layer,
        concurrency_layer,
        circuit_layer,
        circuit_store_recovers,
        stream_response,
        stream_request,
        custom_adapter,
        no_content_response,
        head_request
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(hackney),
    %% An atomics ref survives the init_per_suite process (unlike an ETS
    %% table owned by it) and gives handle_flaky a shared counter.
    Counter = atomics:new(1, [{signed, false}]),
    Router = livery_router:compile([
        {<<"GET">>, <<"/ok">>, fun handle_ok/1},
        {<<"POST">>, <<"/echo">>, fun handle_echo/1},
        {<<"GET">>, <<"/slow">>, fun handle_slow/1},
        {<<"GET">>, <<"/flaky">>, fun handle_flaky/1},
        {<<"GET">>, <<"/big">>, fun handle_big/1},
        {<<"GET">>, <<"/block">>, fun handle_block/1},
        {<<"GET">>, <<"/empty">>, fun handle_no_content/1},
        {<<"HEAD">>, <<"/ping">>, fun handle_ok/1}
    ]),
    {ok, Pid} = livery:start_service(#{
        http => #{port => 0},
        config => #{counter => Counter},
        router => Router
    }),
    %% start_service links to us; unlink so the service survives the
    %% init_per_suite process and lives for the whole suite.
    true = unlink(Pid),
    Port = maps:get(h1, livery:which_listeners(Pid)),
    Base = iolist_to_binary([<<"http://127.0.0.1:">>, integer_to_binary(Port)]),
    [{service, Pid}, {counter, Counter}, {base, Base} | Config].

end_per_suite(Config) ->
    livery:stop_service(?config(service, Config)),
    ok.

%%====================================================================
%% Handlers
%%====================================================================

handle_ok(_Req) -> livery_resp:text(200, <<"ok">>).

handle_echo(Req) -> livery_resp:text(200, read_body(Req)).

handle_slow(_Req) ->
    timer:sleep(300),
    livery_resp:text(200, <<"slow">>).

%% Fail the first two calls with 503, then succeed.
handle_flaky(Req) ->
    Ref = livery_req:config(counter, Req),
    case atomics:add_get(Ref, 1, 1) of
        N when N =< 2 -> livery_resp:text(503, <<"busy">>);
        _ -> livery_resp:text(200, <<"recovered">>)
    end.

handle_big(_Req) -> livery_resp:text(200, binary:copy(<<"x">>, 100000)).

handle_no_content(_Req) -> livery_resp:empty(204).

handle_block(_Req) ->
    timer:sleep(200),
    livery_resp:text(200, <<"done">>).

read_body(Req) ->
    case livery_req:body(Req) of
        {stream, Reader} ->
            {ok, Bin, _} = livery_body:read_all(Reader),
            Bin;
        {buffered, IoData} ->
            iolist_to_binary(IoData);
        empty ->
            <<>>
    end.

%%====================================================================
%% Cases
%%====================================================================

get_round_trip(Config) ->
    C = livery_client:new(#{base_url => ?config(base, Config)}),
    {ok, Resp} = livery_client:get(C, <<"/ok">>),
    ?assertEqual(200, livery_client:status(Resp)),
    ?assertEqual({full, <<"ok">>}, livery_client:body(Resp)).

post_round_trip(Config) ->
    C = livery_client:new(#{base_url => ?config(base, Config)}),
    {ok, Resp} = livery_client:post(C, <<"/echo">>, <<"hello">>),
    ?assertEqual(200, livery_client:status(Resp)),
    ?assertEqual({full, <<"hello">>}, livery_client:body(Resp)).

timeout_layer(Config) ->
    C = livery_client:new(#{
        base_url => ?config(base, Config),
        stack => [livery_client:timeout(50)]
    }),
    ?assertEqual({error, timeout}, livery_client:get(C, <<"/slow">>)).

retry_layer(Config) ->
    atomics:put(?config(counter, Config), 1, 0),
    C = livery_client:new(#{
        base_url => ?config(base, Config),
        stack => [livery_client:retry(#{max => 5, backoff => {10, 1.2}})]
    }),
    {ok, Resp} = livery_client:get(C, <<"/flaky">>),
    ?assertEqual(200, livery_client:status(Resp)),
    ?assertEqual({full, <<"recovered">>}, livery_client:body(Resp)).

concurrency_layer(Config) ->
    C = livery_client:new(#{
        base_url => ?config(base, Config),
        stack => [livery_client:concurrency(1)]
    }),
    Self = self(),
    [spawn(fun() -> Self ! {res, livery_client:get(C, <<"/block">>)} end) || _ <- [1, 2, 3]],
    Results = [
        receive
            {res, R} -> R
        after 5000 -> timeout
        end
     || _ <- [1, 2, 3]
    ],
    ?assert(lists:member({error, overloaded}, Results)),
    ?assert(
        lists:any(
            fun
                ({ok, _}) -> true;
                (_) -> false
            end,
            Results
        )
    ).

circuit_layer(_Config) ->
    C = livery_client:new(#{
        base_url => dead_base(),
        adapter_opts => #{hackney => [{connect_timeout, 200}]},
        stack => [livery_client:circuit_breaker(#{name => cb_test, window => 3, trip => 0.5})]
    }),
    %% Three real failures trip the breaker (window 3, ratio 1.0 >= 0.5).
    [?assertMatch({error, _}, livery_client:get(C, <<"/x">>)) || _ <- [1, 2, 3]],
    %% Now it fails fast without touching the network.
    ?assertEqual({error, circuit_open}, livery_client:get(C, <<"/x">>)).

circuit_store_recovers(_Config) ->
    Name = {cb_unit, erlang:unique_integer()},
    Cooldown = 50,
    %% Closed: record failures until the window trips it open.
    allow = livery_client_circuit_store:allow(Name, Cooldown),
    ok = livery_client_circuit_store:record(Name, err, 2, 0.5),
    ok = livery_client_circuit_store:record(Name, err, 2, 0.5),
    ?assertEqual(deny, livery_client_circuit_store:allow(Name, Cooldown)),
    %% After the cooldown it half-opens to probe, and a success closes it.
    timer:sleep(Cooldown + 20),
    ?assertEqual(allow, livery_client_circuit_store:allow(Name, Cooldown)),
    ok = livery_client_circuit_store:record(Name, ok, 2, 0.5),
    ?assertEqual(allow, livery_client_circuit_store:allow(Name, Cooldown)),
    livery_client_circuit_store:reset(Name).

stream_response(Config) ->
    C = livery_client:new(#{base_url => ?config(base, Config)}),
    {ok, Resp} = livery_client:request(C, get, <<"/big">>, #{stream => true}),
    {stream, Reader} = livery_client:body(Resp),
    {ok, Body} = livery_client:read_body(Reader),
    ?assertEqual(100000, byte_size(Body)).

stream_request(Config) ->
    C = livery_client:new(#{base_url => ?config(base, Config)}),
    Body = {stream, producer([<<"a">>, <<"b">>, <<"c">>])},
    {ok, Resp} = livery_client:request(C, post, <<"/echo">>, #{body => Body}),
    ?assertEqual({full, <<"abc">>}, livery_client:body(Resp)).

custom_adapter(_Config) ->
    C = livery_client:new(#{adapter => livery_client_fake_adapter}),
    {ok, Resp} = livery_client:get(C, <<"http://ignored/">>),
    ?assertEqual(418, livery_client:status(Resp)),
    ?assertEqual({full, <<"teapot">>}, livery_client:body(Resp)).

%% A 204 carries no body; the adapter must surface it as an empty-bodied
%% response.
no_content_response(Config) ->
    C = livery_client:new(#{base_url => ?config(base, Config)}),
    {ok, Resp} = livery_client:get(C, <<"/empty">>),
    ?assertEqual(204, livery_client:status(Resp)),
    ?assertEqual({full, <<>>}, livery_client:body(Resp)).

%% A HEAD response is always bodyless; same three-element reply path.
head_request(Config) ->
    C = livery_client:new(#{base_url => ?config(base, Config)}),
    {ok, Resp} = livery_client:request(C, head, <<"/ping">>, #{}),
    ?assertEqual(200, livery_client:status(Resp)),
    ?assertEqual({full, <<>>}, livery_client:body(Resp)).

%%====================================================================
%% Helpers
%%====================================================================

producer([]) ->
    fun() -> eof end;
producer([H | T]) ->
    fun() -> {ok, H, producer(T)} end.

%% A loopback port with nothing listening, so connects are refused.
dead_base() ->
    {ok, LSock} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(LSock),
    gen_tcp:close(LSock),
    iolist_to_binary([<<"http://127.0.0.1:">>, integer_to_binary(Port)]).
