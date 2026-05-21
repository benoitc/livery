-module(livery_instrument_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Setup
%%====================================================================

setup() ->
    {ok, _} = application:ensure_all_started(instrument),
    ok.

teardown(_) ->
    ok.

with_instrument_test_() ->
    {setup, fun setup/0, fun teardown/1, [
        fun trace_passes_response_through/0,
        fun trace_extracts_traceparent_header/0,
        fun metrics_passes_response_through/0,
        fun metrics_creates_instruments_once/0,
        fun stacked_trace_and_metrics_compose/0
    ]}.

%%====================================================================
%% Tracing middleware
%%====================================================================

trace_passes_response_through() ->
    Stack = [{livery_instrument_trace, #{}}],
    Cap = livery_test_adapter:run(
        Stack,
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        #{method => <<"GET">>, path => <<"/foo">>}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"ok">>, livery_test_adapter:body(Cap)).

trace_extracts_traceparent_header() ->
    %% A well-formed traceparent should not break the middleware.
    Stack = [{livery_instrument_trace, #{}}],
    TraceParent = <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>,
    Cap = livery_test_adapter:run(
        Stack,
        fun(_R) -> livery_resp:text(200, <<>>) end,
        #{headers => [{<<"traceparent">>, TraceParent}]}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)).

%%====================================================================
%% Metrics middleware
%%====================================================================

metrics_passes_response_through() ->
    Stack = [{livery_instrument_metrics, #{}}],
    Cap = livery_test_adapter:run(
        Stack,
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        #{}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"ok">>, livery_test_adapter:body(Cap)).

metrics_creates_instruments_once() ->
    Stack = [{livery_instrument_metrics, #{meter => <<"livery_test">>}}],
    Handler = fun(_R) -> livery_resp:empty(204) end,
    %% First call creates and caches the instruments; subsequent
    %% calls reuse them. We can't easily inspect the cache but a
    %% second call should not crash on duplicate-instrument errors.
    _ = livery_test_adapter:run(Stack, Handler, #{}),
    _ = livery_test_adapter:run(Stack, Handler, #{}),
    ?assertMatch(
        {_, _},
        persistent_term:get({livery_instrument_metrics, <<"livery_test">>})
    ).

%%====================================================================
%% Composition
%%====================================================================

stacked_trace_and_metrics_compose() ->
    Stack = [
        {livery_instrument_trace, #{}},
        {livery_instrument_metrics, #{meter => <<"livery_compose">>}}
    ],
    Cap = livery_test_adapter:run(
        Stack,
        fun(_R) -> livery_resp:text(201, <<"made">>) end,
        #{method => <<"POST">>, path => <<"/items">>}
    ),
    ?assertEqual(201, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"made">>, livery_test_adapter:body(Cap)).

%%====================================================================
%% Logger bridge: logs inside a traced request carry trace context
%%====================================================================

logs_carry_trace_context_test() ->
    {ok, _} = application:ensure_all_started(instrument),
    Self = self(),
    HandlerId = trace_log_capture,
    Primary = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    ok = livery_instrument_trace:install_logger(),
    ok = logger:add_handler(
        HandlerId,
        ?MODULE,
        #{config => Self, level => all, formatter => {logger_formatter, #{}}}
    ),
    try
        Handler = fun(_R) ->
            logger:log(info, #{marker => livery_trace_test}, #{}),
            livery_resp:text(200, <<"ok">>)
        end,
        _ = livery_test_adapter:run([{livery_instrument_trace, #{}}], Handler, #{}),
        Meta = wait_trace_meta(500),
        ?assert(maps:is_key(trace_id, Meta)),
        ?assert(maps:is_key(span_id, Meta))
    after
        logger:remove_handler(HandlerId),
        livery_instrument_trace:uninstall_logger(),
        logger:set_primary_config(level, maps:get(level, Primary))
    end.

wait_trace_meta(Timeout) ->
    receive
        {log_event, #{
            msg := {report, #{marker := livery_trace_test}},
            meta := Meta
        }} ->
            Meta;
        {log_event, _Other} ->
            wait_trace_meta(Timeout)
    after Timeout ->
        #{}
    end.

%% logger handler callback used by logs_carry_trace_context_test
log(Event, #{config := Pid}) ->
    Pid ! {log_event, Event},
    ok.
