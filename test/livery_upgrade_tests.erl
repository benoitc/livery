%% WebSocket and WebTransport go through any adapter that implements
%% accept_ws/4 or accept_wt/4, not only the ones Livery ships.
-module(livery_upgrade_tests).

-include_lib("eunit/include/eunit.hrl").

req(Adapter, Stream) ->
    livery_req:new(#{
        protocol => h2,
        method => <<"CONNECT">>,
        path => <<"/">>,
        adapter => Adapter,
        stream => Stream
    }).

with_probe(Fun) ->
    true = register(livery_upgrade_probe, self()),
    try
        Fun()
    after
        unregister(livery_upgrade_probe)
    end.

ws_through_any_adapter_with_accept_ws_test() ->
    with_probe(fun() ->
        Stream = make_ref(),
        Resp = livery_ws:upgrade(req(livery_upgrade_fake_adapter, Stream), my_ws, #{}),
        ?assertEqual(101, livery_resp:status(Resp)),
        ?assertEqual(taken_over, livery_resp:body(Resp)),
        receive
            {accept_ws, Got, my_ws} -> ?assertEqual(Stream, Got)
        after 1000 -> error(accept_ws_not_called)
        end
    end).

wt_through_any_adapter_with_accept_wt_test() ->
    with_probe(fun() ->
        Stream = make_ref(),
        Resp = livery_wt:upgrade(req(livery_upgrade_fake_adapter, Stream), my_wt, #{}),
        ?assertEqual(200, livery_resp:status(Resp)),
        ?assertEqual(taken_over, livery_resp:body(Resp)),
        receive
            {accept_wt, Got, my_wt} -> ?assertEqual(Stream, Got)
        after 1000 -> error(accept_wt_not_called)
        end
    end).

adapter_without_upgrade_callbacks_is_501_test() ->
    Req = req(livery_test_adapter, make_ref()),
    ?assertEqual(501, livery_resp:status(livery_ws:upgrade(Req, my_ws, #{}))),
    ?assertEqual(501, livery_resp:status(livery_wt:upgrade(Req, my_wt, #{}))).
