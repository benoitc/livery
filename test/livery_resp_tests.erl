-module(livery_resp_tests).

-include_lib("eunit/include/eunit.hrl").
-include("livery.hrl").

text_sets_content_type_test() ->
    R = livery_resp:text(200, <<"hi">>),
    ?assertEqual(200, livery_resp:status(R)),
    ?assertEqual({full, <<"hi">>}, livery_resp:body(R)),
    ?assertEqual(<<"text/plain; charset=utf-8">>,
                 header(R, <<"content-type">>)).

json_sets_content_type_test() ->
    R = livery_resp:json(200, <<"{\"a\":1}">>),
    ?assertEqual(<<"application/json">>, header(R, <<"content-type">>)).

user_content_type_wins_test() ->
    R = livery_resp:text(200,
        [{<<"Content-Type">>, <<"text/markdown">>}], <<"hi">>),
    ?assertEqual(<<"text/markdown">>, header(R, <<"content-type">>)),
    %% And no duplicate.
    CT = [V || {N, V} <- livery_resp:headers(R), N =:= <<"content-type">>],
    ?assertEqual([<<"text/markdown">>], CT).

sse_sets_event_stream_and_no_cache_test() ->
    R = livery_resp:sse(200, fun(_) -> ok end),
    ?assertEqual(<<"text/event-stream">>, header(R, <<"content-type">>)),
    ?assertEqual(<<"no-cache">>, header(R, <<"cache-control">>)),
    ?assertMatch({sse, _}, livery_resp:body(R)).

redirect_sets_location_test() ->
    R = livery_resp:redirect(302, <<"/new">>),
    ?assertEqual(302, livery_resp:status(R)),
    ?assertEqual(<<"/new">>, header(R, <<"location">>)),
    ?assertEqual(empty, livery_resp:body(R)).

with_status_and_header_compose_test() ->
    R0 = livery_resp:text(200, <<"hi">>),
    R1 = livery_resp:with_status(201, R0),
    R2 = livery_resp:with_header(<<"X-Req-Id">>, <<"abc">>, R1),
    R3 = livery_resp:with_header(<<"x-req-id">>, <<"def">>, R2),
    ?assertEqual(201, livery_resp:status(R3)),
    ?assertEqual(<<"def">>, header(R3, <<"x-req-id">>)).

append_header_preserves_order_test() ->
    R0 = livery_resp:empty(204),
    R1 = livery_resp:append_header(<<"Set-Cookie">>, <<"a=1">>, R0),
    R2 = livery_resp:append_header(<<"Set-Cookie">>, <<"b=2">>, R1),
    Cookies = [V || {N, V} <- livery_resp:headers(R2),
                    N =:= <<"set-cookie">>],
    ?assertEqual([<<"a=1">>, <<"b=2">>], Cookies).

upgrade_is_101_with_body_tag_test() ->
    R = livery_resp:upgrade(ws, some_state),
    ?assertEqual(101, livery_resp:status(R)),
    ?assertEqual({upgrade, ws, some_state}, livery_resp:body(R)).

file_keeps_range_test() ->
    R = livery_resp:file(200, "/tmp/x"),
    ?assertEqual({file, "/tmp/x", undefined}, livery_resp:body(R)),
    R2 = livery_resp:file(206, "/tmp/x", {100, 200}),
    ?assertEqual({file, "/tmp/x", {100, 200}}, livery_resp:body(R2)).

trailers_passthrough_test() ->
    R0 = livery_resp:text(200, <<"hi">>),
    ?assertEqual(undefined, livery_resp:trailers(R0)),
    R1 = livery_resp:with_trailers([{<<"grpc-status">>, <<"0">>}], R0),
    ?assertEqual([{<<"grpc-status">>, <<"0">>}], livery_resp:trailers(R1)).

%%====================================================================
%% Helpers
%%====================================================================

header(Resp, Name) ->
    case lists:keyfind(Name, 1, livery_resp:headers(Resp)) of
        {_, V} -> V;
        false  -> undefined
    end.
