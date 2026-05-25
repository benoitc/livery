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
        fun metrics_registers_instruments/0,
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

%% Instruments are resolved from instrument's own registry (no livery
%% cache). Two requests do not crash on duplicate creation, and the
%% instrument is registered by name.
metrics_registers_instruments() ->
    Stack = [{livery_instrument_metrics, #{meter => <<"livery_test">>}}],
    Handler = fun(_R) -> livery_resp:empty(204) end,
    _ = livery_test_adapter:run(Stack, Handler, #{}),
    _ = livery_test_adapter:run(Stack, Handler, #{}),
    ?assertNotEqual(
        undefined,
        instrument_meter:get_instrument(<<"http.server.active_requests">>)
    ),
    ?assertNotEqual(
        undefined,
        instrument_meter:get_instrument(<<"http.server.request.duration">>)
    ).

%% A request while the instrument registry is down must be served without
%% metrics, not 500. Instruments are keyed globally by name, so the
%% fixture-registered names are unregistered first to force the create
%% path, then the app is stopped so the registry gen_server:call exits
%% `noproc' (caught by instruments/1 -> skip). Plain stop/1 does not clear
%% the otel persistent_term, hence the unregister-first step.
metrics_serves_request_when_registry_down_test() ->
    {ok, _} = application:ensure_all_started(instrument),
    _ = instrument_meter:unregister_instrument(<<"http.server.active_requests">>),
    _ = instrument_meter:unregister_instrument(<<"http.server.request.duration">>),
    ok = application:stop(instrument),
    try
        Stack = [{livery_instrument_metrics, #{meter => <<"livery_registry_down">>}}],
        Cap = livery_test_adapter:run(
            Stack, fun(_R) -> livery_resp:text(200, <<"ok">>) end, #{}
        ),
        ?assertEqual(200, livery_test_adapter:status(Cap))
    after
        {ok, _} = application:ensure_all_started(instrument)
    end.

%% Livery resolves instruments fresh from the registry on each request, so
%% a cleared registry self-heals: the next request re-creates and
%% re-registers the instruments rather than silently losing them. The
%% clean slate is produced by unregistering livery's own two instruments
%% (mirroring the cleanup instrument 1.1.2 runs in init/1 on a registry
%% restart) - deterministic, with no flaky application stop/start and no
%% global registry wipe that could perturb other tests.
metrics_self_heal_after_registry_reset_test() ->
    {ok, _} = application:ensure_all_started(instrument),
    Active = <<"http.server.active_requests">>,
    Duration = <<"http.server.request.duration">>,
    Stack = [{livery_instrument_metrics, #{meter => <<"livery_reset">>}}],
    Handler = fun(_R) -> livery_resp:text(200, <<"ok">>) end,
    _ = livery_test_adapter:run(Stack, Handler, #{}),
    ?assertNotEqual(undefined, instrument_meter:get_instrument(Active)),
    _ = instrument_meter:unregister_instrument(Active),
    _ = instrument_meter:unregister_instrument(Duration),
    ?assertEqual(undefined, instrument_meter:get_instrument(Active)),
    Cap = livery_test_adapter:run(Stack, Handler, #{}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    %% Re-created and re-registered on the next request (self-heal).
    ?assertNotEqual(undefined, instrument_meter:get_instrument(Active)),
    ?assertNotEqual(undefined, instrument_meter:get_instrument(Duration)).

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
