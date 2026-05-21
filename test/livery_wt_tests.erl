-module(livery_wt_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%% WebTransport is not available on H1 (or the in-memory test
%% adapter); upgrade/3 returns 501 there. These EUnit cases cover
%% that fallback; the H2/H3 bridge to webtransport:accept/4 is
%% exercised end-to-end in livery_wt_SUITE.

upgrade_on_test_adapter_returns_501_test() ->
    Cap = livery_test_adapter:run(
        [],
        fun(R) -> livery_wt:upgrade(R, some_wt_handler, #{}) end,
        #{method => <<"CONNECT">>, path => <<"/wt">>}
    ),
    ?assertEqual(501, livery_test_adapter:status(Cap)),
    ?assertEqual(
        <<"WebTransport not supported on this protocol">>,
        livery_test_adapter:body(Cap)
    ).

upgrade_returns_response_value_test() ->
    %% Direct call with a synthetic req whose adapter is the in-memory
    %% test adapter (no WT support) yields a 501 resp value.
    Req = livery_req:new(#{method => <<"CONNECT">>, path => <<"/wt">>}),
    Req1 = livery_req:set_meta(noop, true, Req),
    Resp = livery_wt:upgrade(
        set_adapter(Req1, livery_test_adapter),
        some_wt_handler,
        #{}
    ),
    ?assertEqual(501, livery_resp:status(Resp)).

%% Helper: stamp the adapter field (normally set by the real adapter
%% when it builds the request).
set_adapter(Req, Adapter) ->
    %% livery_req has no public adapter setter; round-trip through new/1.
    Fields = #{
        method => livery_req:method(Req),
        path => livery_req:path(Req),
        adapter => Adapter
    },
    livery_req:new(Fields).
