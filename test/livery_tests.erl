-module(livery_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").
-include("livery.hrl").

%%====================================================================
%% dispatch/3
%%====================================================================

dispatch_runs_handler_when_stack_empty_test() ->
    Req = livery_req:new(#{}),
    Resp = livery:dispatch([], fun(_R) -> livery_resp:text(200, <<"ok">>) end, Req),
    ?assertEqual(200, livery_resp:status(Resp)).

dispatch_threads_request_through_middleware_test() ->
    Stack = [livery_middleware:before(
                fun(R) -> livery_req:set_meta(seen, yes, R) end)],
    Handler = fun(R) ->
        case livery_req:meta(seen, R) of
            yes -> livery_resp:text(200, <<"tagged">>);
            _   -> livery_resp:text(500, <<>>)
        end
    end,
    Resp = livery:dispatch(Stack, Handler, livery_req:new(#{})),
    ?assertEqual(<<"tagged">>, body(Resp)).

dispatch_short_circuit_skips_handler_test() ->
    Resp = livery:dispatch(
        [fun(_R, _N) -> livery_resp:text(401, <<>>) end],
        fun(_R) -> error(must_not_be_called) end,
        livery_req:new(#{})),
    ?assertEqual(401, livery_resp:status(Resp)).

%%====================================================================
%% emit/3 body variants
%%====================================================================

emit_empty_body_closes_stream_test() ->
    {Cap, _} = emit_through(livery_resp:empty(204)),
    ?assertEqual(204, livery_test_adapter:status(Cap)),
    ?assertEqual(<<>>, livery_test_adapter:body(Cap)),
    ?assert(livery_test_adapter:end_stream(Cap)).

emit_full_body_test() ->
    {Cap, _} = emit_through(livery_resp:text(200, <<"hello">>)),
    ?assertEqual(<<"hello">>, livery_test_adapter:body(Cap)),
    ?assert(livery_test_adapter:end_stream(Cap)).

emit_full_iolist_body_test() ->
    Resp = livery_resp:new(200, [], {full, [<<"a">>, [<<"b">>, <<"c">>], <<"d">>]}),
    {Cap, _} = emit_through(Resp),
    ?assertEqual(<<"abcd">>, livery_test_adapter:body(Cap)).

emit_full_zero_byte_no_trailers_uses_single_headers_call_test() ->
    Resp = livery_resp:new(200, [], {full, <<>>}),
    {Cap, _} = emit_through(Resp),
    ?assertEqual(<<>>, livery_test_adapter:body(Cap)),
    ?assert(livery_test_adapter:end_stream(Cap)).

emit_full_zero_byte_with_trailers_test() ->
    Resp0 = livery_resp:new(200, [], {full, <<>>}),
    Resp = livery_resp:with_trailers([{<<"x-end">>, <<"yes">>}], Resp0),
    {Cap, _} = emit_through(Resp),
    ?assertEqual([{<<"x-end">>, <<"yes">>}],
                 livery_test_adapter:trailers(Cap)),
    ?assert(livery_test_adapter:end_stream(Cap)).

emit_chunked_test() ->
    Producer = fun(Emit) ->
        Emit(<<"a">>),
        Emit(<<"b">>),
        Emit(<<"c">>),
        ok
    end,
    {Cap, _} = emit_through(livery_resp:stream(200, [], Producer)),
    ?assertEqual(<<"abc">>, livery_test_adapter:body(Cap)),
    ?assert(livery_test_adapter:end_stream(Cap)).

emit_chunked_with_trailers_test() ->
    Producer = fun(Emit) -> Emit(<<"data">>), ok end,
    Resp0 = livery_resp:stream(200, [], Producer),
    Resp = livery_resp:with_trailers([{<<"x-fin">>, <<"1">>}], Resp0),
    {Cap, _} = emit_through(Resp),
    ?assertEqual([{<<"x-fin">>, <<"1">>}],
                 livery_test_adapter:trailers(Cap)).

emit_sse_default_data_only_test() ->
    Producer = fun(Emit) -> Emit(<<"plain">>), ok end,
    {Cap, _} = emit_through(livery_resp:sse(200, Producer)),
    ?assertEqual(<<"data: plain\n\n">>, livery_test_adapter:body(Cap)).

emit_sse_with_event_id_retry_test() ->
    Producer = fun(Emit) ->
        Emit(#{event => <<"tick">>, id => <<"42">>,
               retry => 1500, data => <<"v">>})
    end,
    {Cap, _} = emit_through(livery_resp:sse(200, Producer)),
    Expected = <<"event: tick\nid: 42\nretry: 1500\ndata: v\n\n">>,
    ?assertEqual(Expected, livery_test_adapter:body(Cap)).

emit_sse_iolist_data_test() ->
    Producer = fun(Emit) -> Emit(#{data => [<<"a">>, <<"b">>]}) end,
    {Cap, _} = emit_through(livery_resp:sse(200, Producer)),
    ?assertEqual(<<"data: ab\n\n">>, livery_test_adapter:body(Cap)).

emit_file_resets_stream_test() ->
    Resp = livery_resp:file(200, "/tmp/nope"),
    {Cap, R} = emit_through(Resp),
    ?assertEqual({error, not_implemented}, R),
    ?assertEqual(file_emission_not_implemented,
                 livery_test_adapter:reset_reason(Cap)).

emit_upgrade_resets_stream_test() ->
    Resp = livery_resp:upgrade(ws, undefined),
    {Cap, R} = emit_through(Resp),
    ?assertEqual({error, not_implemented}, R),
    ?assertEqual(upgrade_not_handled_at_emit,
                 livery_test_adapter:reset_reason(Cap)).

emit_with_fun_trailers_test() ->
    Trailer = fun() -> [{<<"x-late">>, <<"1">>}] end,
    Resp0 = livery_resp:text(200, <<"body">>),
    Resp = livery_resp:with_trailers(Trailer, Resp0),
    {Cap, _} = emit_through(Resp),
    ?assertEqual([{<<"x-late">>, <<"1">>}],
                 livery_test_adapter:trailers(Cap)).

%%====================================================================
%% Service lifecycle stubs (current placeholders)
%%====================================================================

start_listener_rejects_unknown_adapter_test() ->
    ?assertEqual({error, unknown_adapter},
                 livery:start_listener(foo, #{})).

stop_listener_rejects_unknown_handle_test() ->
    ?assertEqual({error, unknown_listener},
                 livery:stop_listener({foo, bar})).

%%====================================================================
%% router_handler/1,2
%%====================================================================

router_handler_routes_and_binds_test() ->
    Router = livery_router:compile([
        {<<"GET">>, <<"/">>,         {?MODULE, rh_index}},
        {<<"GET">>, <<"/hi/:name">>, {?MODULE, rh_greet}}
    ]),
    H = livery:router_handler(Router),
    Cap1 = livery_test_adapter:run([], H,
        #{method => <<"GET">>, path => <<"/">>}),
    ?assertEqual(<<"index">>, livery_test_adapter:body(Cap1)),
    Cap2 = livery_test_adapter:run([], H,
        #{method => <<"GET">>, path => <<"/hi/ada">>}),
    ?assertEqual(<<"hello, ada">>, livery_test_adapter:body(Cap2)).

router_handler_fun_route_test() ->
    Router = livery_router:compile([
        {<<"GET">>, <<"/ping">>, fun(_R) -> livery_resp:text(200, <<"pong">>) end}
    ]),
    H = livery:router_handler(Router),
    Cap = livery_test_adapter:run([], H,
        #{method => <<"GET">>, path => <<"/ping">>}),
    ?assertEqual(<<"pong">>, livery_test_adapter:body(Cap)).

router_handler_not_found_test() ->
    Router = livery_router:compile([{<<"GET">>, <<"/">>, {?MODULE, rh_index}}]),
    H = livery:router_handler(Router),
    Cap = livery_test_adapter:run([], H,
        #{method => <<"GET">>, path => <<"/missing">>}),
    ?assertEqual(404, livery_test_adapter:status(Cap)).

router_handler_method_not_allowed_sets_allow_test() ->
    Router = livery_router:compile([
        {<<"GET">>,  <<"/x">>, {?MODULE, rh_index}},
        {<<"POST">>, <<"/x">>, {?MODULE, rh_index}}
    ]),
    H = livery:router_handler(Router),
    Cap = livery_test_adapter:run([], H,
        #{method => <<"DELETE">>, path => <<"/x">>}),
    ?assertEqual(405, livery_test_adapter:status(Cap)),
    Allow = livery_test_adapter:header(<<"allow">>, Cap),
    ?assertNotEqual(nomatch, binary:match(Allow, <<"GET">>)),
    ?assertNotEqual(nomatch, binary:match(Allow, <<"POST">>)).

router_handler_custom_fallbacks_test() ->
    Router = livery_router:compile([{<<"GET">>, <<"/">>, {?MODULE, rh_index}}]),
    H = livery:router_handler(Router, #{
        not_found => fun(_R) -> livery_resp:text(404, <<"nope">>) end,
        method_not_allowed => fun(_R, _M) -> livery_resp:text(405, <<"no">>) end
    }),
    Cap = livery_test_adapter:run([], H,
        #{method => <<"GET">>, path => <<"/missing">>}),
    ?assertEqual(<<"nope">>, livery_test_adapter:body(Cap)).

%% Route handlers used by the router_handler tests.
rh_index(_Req) -> livery_resp:text(200, <<"index">>).
rh_greet(Req) -> livery_resp:text(200, [<<"hello, ">>, livery_req:binding(<<"name">>, Req)]).

%%====================================================================
%% Helpers
%%====================================================================

emit_through(Resp) ->
    Tab = livery_test_adapter:start(),
    try
        Stream = livery_test_adapter:new_stream(Tab),
        R = livery:emit(livery_test_adapter, Stream, Resp),
        {livery_test_adapter:capture(Stream), R}
    after
        livery_test_adapter:stop(Tab)
    end.

body(Resp) ->
    case livery_resp:body(Resp) of
        {full, B} -> iolist_to_binary(B);
        Other     -> Other
    end.
