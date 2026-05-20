-module(livery_test_adapter_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Capture mechanics
%%====================================================================

start_stop_test() ->
    Tab = livery_test_adapter:start(),
    ?assert(is_reference(Tab) orelse Tab =/= undefined),
    ?assertEqual(ok, livery_test_adapter:stop(Tab)).

send_headers_records_status_and_headers_test() ->
    Tab = livery_test_adapter:start(),
    Stream = livery_test_adapter:new_stream(Tab),
    ok = livery_test_adapter:send_headers(Stream, 200,
        [{<<"content-type">>, <<"text/plain">>}], #{end_stream => false}),
    Cap = livery_test_adapter:capture(Stream),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"text/plain">>,
                 livery_test_adapter:header(<<"content-type">>, Cap)),
    ?assertNot(livery_test_adapter:end_stream(Cap)),
    livery_test_adapter:stop(Tab).

send_data_accumulates_in_order_test() ->
    Tab = livery_test_adapter:start(),
    Stream = livery_test_adapter:new_stream(Tab),
    livery_test_adapter:send_headers(Stream, 200, [], #{end_stream => false}),
    livery_test_adapter:send_data(Stream, <<"ab">>, #{end_stream => false}),
    livery_test_adapter:send_data(Stream, <<"cd">>, #{end_stream => false}),
    livery_test_adapter:send_data(Stream, <<"ef">>, #{end_stream => true}),
    Cap = livery_test_adapter:capture(Stream),
    ?assertEqual(<<"abcdef">>, livery_test_adapter:body(Cap)),
    ?assert(livery_test_adapter:end_stream(Cap)),
    livery_test_adapter:stop(Tab).

send_trailers_closes_stream_test() ->
    Tab = livery_test_adapter:start(),
    Stream = livery_test_adapter:new_stream(Tab),
    livery_test_adapter:send_headers(Stream, 200, [], #{end_stream => false}),
    livery_test_adapter:send_trailers(Stream, [{<<"x-checksum">>, <<"abc">>}]),
    Cap = livery_test_adapter:capture(Stream),
    ?assertEqual([{<<"x-checksum">>, <<"abc">>}],
                 livery_test_adapter:trailers(Cap)),
    ?assert(livery_test_adapter:end_stream(Cap)),
    livery_test_adapter:stop(Tab).

reset_records_reason_test() ->
    Tab = livery_test_adapter:start(),
    Stream = livery_test_adapter:new_stream(Tab),
    livery_test_adapter:reset(Stream, peer_gone),
    Cap = livery_test_adapter:capture(Stream),
    ?assertEqual(peer_gone, livery_test_adapter:reset_reason(Cap)),
    livery_test_adapter:stop(Tab).

%%====================================================================
%% run/3 end-to-end
%%====================================================================

run_emits_full_body_test() ->
    Cap = livery_test_adapter:run(
        [],
        fun(_Req) -> livery_resp:text(200, <<"hello">>) end,
        #{method => <<"GET">>, path => <<"/">>}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"hello">>, livery_test_adapter:body(Cap)),
    ?assertEqual(<<"text/plain; charset=utf-8">>,
                 livery_test_adapter:header(<<"content-type">>, Cap)),
    ?assert(livery_test_adapter:end_stream(Cap)).

run_emits_empty_response_test() ->
    Cap = livery_test_adapter:run(
        [],
        fun(_Req) -> livery_resp:empty(204) end,
        #{}),
    ?assertEqual(204, livery_test_adapter:status(Cap)),
    ?assertEqual(<<>>, livery_test_adapter:body(Cap)),
    ?assert(livery_test_adapter:end_stream(Cap)).

run_emits_streaming_chunks_test() ->
    Producer = fun(Emit) ->
        Emit(<<"chunk1">>),
        Emit(<<"chunk2">>),
        ok
    end,
    Cap = livery_test_adapter:run(
        [],
        fun(_Req) -> livery_resp:stream(200, [], Producer) end,
        #{}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"chunk1chunk2">>, livery_test_adapter:body(Cap)),
    ?assert(livery_test_adapter:end_stream(Cap)).

run_emits_sse_frames_test() ->
    Producer = fun(Emit) ->
        Emit(#{event => <<"tick">>, data => <<"1">>}),
        Emit(#{event => <<"tick">>, data => <<"2">>}),
        ok
    end,
    Cap = livery_test_adapter:run(
        [],
        fun(_Req) -> livery_resp:sse(200, Producer) end,
        #{}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    Body = livery_test_adapter:body(Cap),
    ?assertEqual(<<"event: tick\ndata: 1\n\nevent: tick\ndata: 2\n\n">>, Body),
    ?assertEqual(<<"text/event-stream">>,
                 livery_test_adapter:header(<<"content-type">>, Cap)).

run_with_middleware_test() ->
    Stack = [
        livery_middleware:after_response(fun(R) ->
            livery_resp:with_header(<<"X-Wrapped">>, <<"1">>, R)
        end)
    ],
    Cap = livery_test_adapter:run(
        Stack,
        fun(_Req) -> livery_resp:text(200, <<"ok">>) end,
        #{}),
    ?assertEqual(<<"1">>, livery_test_adapter:header(<<"x-wrapped">>, Cap)).

run_middleware_short_circuit_test() ->
    Stack = [fun(_Req, _Next) -> livery_resp:text(401, <<"nope">>) end],
    Cap = livery_test_adapter:run(
        Stack,
        fun(_Req) -> error(must_not_be_called) end,
        #{}),
    ?assertEqual(401, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"nope">>, livery_test_adapter:body(Cap)).

run_threads_request_to_handler_test() ->
    Handler = fun(R) ->
        Method = livery_req:method(R),
        Path = livery_req:path(R),
        livery_resp:text(200, [Method, <<" ">>, Path])
    end,
    Cap = livery_test_adapter:run(
        [], Handler,
        #{method => <<"POST">>, path => <<"/items">>}),
    ?assertEqual(<<"POST /items">>, livery_test_adapter:body(Cap)).

%%====================================================================
%% peer_info and capabilities
%%====================================================================

peer_info_test() ->
    Tab = livery_test_adapter:start(),
    Stream = livery_test_adapter:new_stream(Tab),
    Info = livery_test_adapter:peer_info(Stream),
    ?assertMatch(#{peer := {{127, 0, 0, 1}, 0}}, Info),
    livery_test_adapter:stop(Tab).

capabilities_test() ->
    Tab = livery_test_adapter:start(),
    Caps = livery_test_adapter:capabilities(Tab),
    ?assertMatch(#{trailers := true, extended_connect := true,
                   datagrams := false, capsules := false}, Caps),
    livery_test_adapter:stop(Tab).
