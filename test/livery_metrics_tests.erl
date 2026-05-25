-module(livery_metrics_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%% The instrument registry needs the application running.
metrics_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"200 with Prometheus content-type", fun content_type/0},
        {"records and exports a metric", fun records/0}
    ]}.

setup() ->
    %% The metrics handler and the instrument middleware only need the
    %% `instrument' app (the registry). Avoid starting/stopping the full
    %% `livery' app so this module does not perturb other test modules.
    {ok, _} = application:ensure_all_started(instrument),
    ok.

cleanup(_) ->
    ok.

content_type() ->
    Cap = livery_test_adapter:run(
        [], livery_metrics:handler(), #{method => <<"GET">>}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(
        <<"text/plain; version=0.0.4; charset=utf-8">>,
        livery_test_adapter:header(<<"content-type">>, Cap)
    ).

records() ->
    %% Register a uniquely-named metric directly (instrument keys
    %% instruments by name globally, so reusing the http.server.* names
    %% here would collide with livery_instrument_tests). This proves the
    %% endpoint renders the registry without touching shared names.
    Meter = instrument_meter:get_meter(<<"livery_metrics_test">>),
    Counter = instrument_meter:create_counter(
        Meter, <<"livery_metrics_test_hits">>, #{description => <<"test counter">>}
    ),
    _ = instrument_meter:add(Counter, 1, #{}),
    Cap = livery_test_adapter:run(
        [], livery_metrics:handler(), #{method => <<"GET">>}
    ),
    Body = livery_test_adapter:body(Cap),
    ?assertNotEqual(nomatch, binary:match(Body, <<"# HELP">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"# TYPE">>)),
    ?assertNotEqual(
        nomatch, binary:match(Body, <<"livery_metrics_test_hits">>)
    ).
