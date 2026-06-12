-module(livery_resp_tests).

-include_lib("eunit/include/eunit.hrl").
-include("livery.hrl").

text_sets_content_type_test() ->
    R = livery_resp:text(200, <<"hi">>),
    ?assertEqual(200, livery_resp:status(R)),
    ?assertEqual({full, <<"hi">>}, livery_resp:body(R)),
    ?assertEqual(
        <<"text/plain; charset=utf-8">>,
        header(R, <<"content-type">>)
    ).

json_sets_content_type_test() ->
    R = livery_resp:json(200, <<"{\"a\":1}">>),
    ?assertEqual(<<"application/json">>, header(R, <<"content-type">>)).

user_content_type_wins_test() ->
    R = livery_resp:text(
        200,
        [{<<"Content-Type">>, <<"text/markdown">>}],
        <<"hi">>
    ),
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
    Cookies = [
        V
     || {N, V} <- livery_resp:headers(R2),
        N =:= <<"set-cookie">>
    ],
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
%% NDJSON builder
%%====================================================================

ndjson_sets_content_type_test() ->
    R = livery_resp:ndjson(200, fun(_) -> ok end),
    ?assertEqual(
        <<"application/x-ndjson">>,
        header(R, <<"content-type">>)
    ),
    ?assertMatch({chunked, _}, livery_resp:body(R)).

ndjson_encodes_each_emitted_term_with_newline_test() ->
    Producer = fun(Emit) ->
        Emit(#{<<"n">> => 1}),
        Emit(#{<<"n">> => 2}),
        ok
    end,
    Cap = livery_test_adapter:run(
        [], fun(_R) -> livery_resp:ndjson(200, Producer) end, #{}
    ),
    ?assertEqual(
        <<"{\"n\":1}\n{\"n\":2}\n">>,
        livery_test_adapter:body(Cap)
    ),
    ?assertEqual(
        <<"application/x-ndjson">>,
        livery_test_adapter:header(<<"content-type">>, Cap)
    ).

ndjson_extra_headers_keep_default_content_type_test() ->
    R = livery_resp:ndjson(
        200,
        [{<<"cache-control">>, <<"no-cache">>}],
        fun(_) -> ok end
    ),
    ?assertEqual(
        <<"application/x-ndjson">>,
        header(R, <<"content-type">>)
    ),
    ?assertEqual(
        <<"no-cache">>,
        header(R, <<"cache-control">>)
    ).

ndjson_user_content_type_wins_test() ->
    R = livery_resp:ndjson(
        200,
        [{<<"Content-Type">>, <<"application/json-seq">>}],
        fun(_) -> ok end
    ),
    ?assertEqual(
        <<"application/json-seq">>,
        header(R, <<"content-type">>)
    ).

resolve_deferred_maps_each_decision_test() ->
    P = fun(_) -> ok end,
    Stream = livery_resp:resolve_deferred({stream, 200, [], P}),
    ?assertEqual(200, livery_resp:status(Stream)),
    ?assertMatch({chunked, _}, livery_resp:body(Stream)),

    Sse = livery_resp:resolve_deferred({sse, 200, [], P}),
    ?assertMatch({sse, _}, livery_resp:body(Sse)),
    ?assertEqual(<<"text/event-stream">>, header(Sse, <<"content-type">>)),

    Ndjson = livery_resp:resolve_deferred({ndjson, 200, [], P}),
    ?assertMatch({chunked, _}, livery_resp:body(Ndjson)),
    ?assertEqual(<<"application/x-ndjson">>, header(Ndjson, <<"content-type">>)),

    Full = livery_resp:resolve_deferred({full, 429, [], <<"x">>}),
    ?assertEqual(429, livery_resp:status(Full)),
    ?assertEqual({full, <<"x">>}, livery_resp:body(Full)).

resolve_deferred_merges_outer_headers_decision_wins_test() ->
    Outer = [
        {<<"x-request-id">>, <<"abc">>},
        {<<"content-type">>, <<"text/plain">>}
    ],
    Decision = {full, 429, [{<<"content-type">>, <<"application/json">>}], <<"{}">>},
    R = livery_resp:resolve_deferred(Outer, Decision),
    ?assertEqual(429, livery_resp:status(R)),
    ?assertEqual(<<"abc">>, header(R, <<"x-request-id">>)),
    ?assertEqual(<<"application/json">>, header(R, <<"content-type">>)).

%%====================================================================
%% Helpers
%%====================================================================

header(Resp, Name) ->
    case lists:keyfind(Name, 1, livery_resp:headers(Resp)) of
        {_, V} -> V;
        false -> undefined
    end.
