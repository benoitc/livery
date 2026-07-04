%% @doc Drives livery_client against a real loopback Livery server (real
%% hackney over the loopback, no external network), exercising each layer.
-module(livery_client_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    get_round_trip/1,
    post_round_trip/1,
    query_round_trip/1,
    timeout_layer/1,
    retry_layer/1,
    query_retry_idempotent/1,
    concurrency_layer/1,
    circuit_layer/1,
    circuit_store_recovers/1,
    stream_response/1,
    stream_request/1,
    push_stream/1,
    push_stream_stop/1,
    push_stream_manual/1,
    custom_adapter/1,
    no_content_response/1,
    head_request/1,
    retry_after_layer/1
]).

all() ->
    [
        get_round_trip,
        post_round_trip,
        query_round_trip,
        timeout_layer,
        retry_layer,
        query_retry_idempotent,
        concurrency_layer,
        circuit_layer,
        circuit_store_recovers,
        stream_response,
        stream_request,
        push_stream,
        push_stream_stop,
        push_stream_manual,
        custom_adapter,
        no_content_response,
        head_request,
        retry_after_layer
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
        {<<"QUERY">>, <<"/search">>, fun handle_echo/1},
        {<<"GET">>, <<"/slow">>, fun handle_slow/1},
        {<<"GET">>, <<"/flaky">>, fun handle_flaky/1},
        {<<"QUERY">>, <<"/flaky">>, fun handle_flaky/1},
        {<<"GET">>, <<"/big">>, fun handle_big/1},
        {<<"GET">>, <<"/chunks">>, fun handle_chunks/1},
        {<<"GET">>, <<"/block">>, fun handle_block/1},
        {<<"GET">>, <<"/empty">>, fun handle_no_content/1},
        {<<"HEAD">>, <<"/ping">>, fun handle_ok/1},
        {<<"GET">>, <<"/retry_after">>, fun handle_retry_after/1}
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

handle_chunks(_Req) ->
    Producer = fun(Emit) ->
        [Emit(<<"chunk", (integer_to_binary(N))/binary>>) || N <- lists:seq(1, 3)],
        ok
    end,
    livery_resp:stream(200, [], Producer).

handle_no_content(_Req) -> livery_resp:empty(204).

%% First call: 503 with Retry-After: 1 second. Then: 200.
handle_retry_after(Req) ->
    Ref = livery_req:config(counter, Req),
    case atomics:add_get(Ref, 1, 1) of
        1 -> livery_resp:text(503, [{<<"retry-after">>, <<"1">>}], <<"slow">>);
        _ -> livery_resp:text(200, <<"ok">>)
    end.

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

query_round_trip(Config) ->
    C = livery_client:new(#{base_url => ?config(base, Config)}),
    {ok, Resp} = livery_client:query(C, <<"/search">>, <<"{\"q\":\"boots\"}">>),
    ?assertEqual(200, livery_client:status(Resp)),
    ?assertEqual({full, <<"{\"q\":\"boots\"}">>}, livery_client:body(Resp)).

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

%% QUERY is idempotent (RFC 10008), so the retry layer replays it.
query_retry_idempotent(Config) ->
    atomics:put(?config(counter, Config), 1, 0),
    C = livery_client:new(#{
        base_url => ?config(base, Config),
        stack => [livery_client:retry(#{max => 5, backoff => {10, 1.2}})]
    }),
    {ok, Resp} = livery_client:query(C, <<"/flaky">>, <<"{}">>),
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

%% Push mode delivers status, then body chunks, then done, in order, to the
%% caller's mailbox, leaving it free to selectively receive between chunks.
push_stream(Config) ->
    C = livery_client:new(#{base_url => ?config(base, Config)}),
    {ok, Resp} = livery_client:request(C, get, <<"/chunks">>, #{
        stream => true, stream_to => self()
    }),
    {push, Ref} = livery_client:body(Resp),
    {Status, Headers} = recv_status(Ref),
    ?assertEqual(200, Status),
    ?assert(is_list(Headers)),
    Body = recv_until_done(Ref, []),
    ?assertEqual(<<"chunk1chunk2chunk3">>, Body).

%% stop_stream mid-flight cancels the download. We pull one chunk, then stop
%% before draining the rest; no further chunk or done message follows, and the
%% relay tears the connection down.
push_stream_stop(Config) ->
    C = livery_client:new(#{base_url => ?config(base, Config)}),
    {ok, Resp} = livery_client:request(C, get, <<"/chunks">>, #{
        stream => true, stream_to => self(), flow => manual
    }),
    {push, Ref} = livery_client:body(Resp),
    {200, _} = recv_status(Ref),
    ok = livery_client:stream_next(Ref),
    receive
        {livery_response, Ref, {chunk, <<"chunk1">>}} -> ok
    after 2000 -> ct:fail(no_first_chunk)
    end,
    ok = livery_client:stop_stream(Ref),
    %% The stream is cancelled: no further chunk or done arrives.
    receive
        {livery_response, Ref, Msg} -> ct:fail({unexpected_after_stop, Msg})
    after 300 -> ok
    end.

%% Under flow => manual the reader pulls one chunk per stream_next; no chunk
%% arrives until asked for.
push_stream_manual(Config) ->
    C = livery_client:new(#{base_url => ?config(base, Config)}),
    {ok, Resp} = livery_client:request(C, get, <<"/chunks">>, #{
        stream => true, stream_to => self(), flow => manual
    }),
    {push, Ref} = livery_client:body(Resp),
    {200, _} = recv_status(Ref),
    %% Nothing is pushed until we ask.
    receive
        {livery_response, Ref, {chunk, _}} -> ct:fail(chunk_without_stream_next)
    after 200 -> ok
    end,
    ok = livery_client:stream_next(Ref),
    receive
        {livery_response, Ref, {chunk, First}} -> ?assertEqual(<<"chunk1">>, First)
    after 2000 -> ct:fail(no_chunk_after_stream_next)
    end,
    %% Pull the rest one at a time to completion.
    Rest = pull_until_done(Ref, []),
    ?assertEqual(<<"chunk2chunk3">>, Rest).

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

%% A retryable response with `Retry-After: 1` is honored (the 1s delay dwarfs
%% the ~50ms backoff), then the retry succeeds.
retry_after_layer(Config) ->
    atomics:put(?config(counter, Config), 1, 0),
    C = livery_client:new(#{
        base_url => ?config(base, Config),
        stack => [livery_client:retry(#{max => 2, backoff => {50, 1.0}})]
    }),
    T0 = erlang:monotonic_time(millisecond),
    {ok, Resp} = livery_client:get(C, <<"/retry_after">>),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assertEqual(200, livery_client:status(Resp)),
    ?assert(Elapsed >= 900).

%%====================================================================
%% Helpers
%%====================================================================

recv_status(Ref) ->
    receive
        {livery_response, Ref, {status, Status, Headers}} -> {Status, Headers}
    after 2000 -> ct:fail(no_status)
    end.

%% Accumulate auto-flow chunks until done.
recv_until_done(Ref, Acc) ->
    receive
        {livery_response, Ref, {chunk, Bin}} -> recv_until_done(Ref, [Bin | Acc]);
        {livery_response, Ref, done} -> iolist_to_binary(lists:reverse(Acc));
        {livery_response, Ref, {error, R}} -> ct:fail({stream_error, R})
    after 2000 -> ct:fail(no_done)
    end.

%% Manual flow: one stream_next per chunk until done.
pull_until_done(Ref, Acc) ->
    ok = livery_client:stream_next(Ref),
    receive
        {livery_response, Ref, {chunk, Bin}} -> pull_until_done(Ref, [Bin | Acc]);
        {livery_response, Ref, done} -> iolist_to_binary(lists:reverse(Acc));
        {livery_response, Ref, {error, R}} -> ct:fail({stream_error, R})
    after 2000 -> ct:fail(no_done)
    end.

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
