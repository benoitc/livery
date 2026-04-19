-module(livery_req_tests).

-include_lib("eunit/include/eunit.hrl").
-include("livery.hrl").

new_normalizes_header_names_test() ->
    Req = livery_req:new(#{
        protocol => h1,
        method => <<"GET">>,
        path => <<"/a">>,
        headers => [{<<"Host">>, <<"x">>}, {<<"Accept-Encoding">>, <<"gzip">>}]
    }),
    ?assertEqual([{<<"host">>, <<"x">>}, {<<"accept-encoding">>, <<"gzip">>}],
                 livery_req:headers(Req)).

header_lookup_is_case_insensitive_test() ->
    Req = livery_req:new(#{
        protocol => h2,
        method => <<"GET">>,
        path => <<"/">>,
        headers => [{<<"content-type">>, <<"application/json">>}]
    }),
    ?assertEqual(<<"application/json">>, livery_req:header(<<"Content-Type">>, Req)),
    ?assertEqual(<<"application/json">>, livery_req:header(<<"content-type">>, Req)),
    ?assertEqual(undefined, livery_req:header(<<"X-Missing">>, Req)),
    ?assertEqual(<<"d">>, livery_req:header(<<"X-Missing">>, Req, <<"d">>)),
    ?assert(livery_req:has_header(<<"CONTENT-TYPE">>, Req)).

headers_all_returns_wire_order_test() ->
    Req = livery_req:new(#{
        protocol => h1,
        method => <<"GET">>,
        path => <<"/">>,
        headers => [
            {<<"set-cookie">>, <<"a=1">>},
            {<<"set-cookie">>, <<"b=2">>},
            {<<"host">>, <<"x">>}
        ]
    }),
    ?assertEqual([<<"a=1">>, <<"b=2">>],
                 livery_req:headers_all(<<"set-cookie">>, Req)).

set_header_replaces_all_test() ->
    Req0 = livery_req:new(#{
        protocol => h1, method => <<"GET">>, path => <<"/">>,
        headers => [{<<"x-a">>, <<"1">>}, {<<"x-a">>, <<"2">>}]
    }),
    Req1 = livery_req:set_header(<<"X-A">>, <<"9">>, Req0),
    ?assertEqual([<<"9">>], livery_req:headers_all(<<"x-a">>, Req1)).

append_header_keeps_order_test() ->
    Req0 = livery_req:new(#{
        protocol => h1, method => <<"GET">>, path => <<"/">>,
        headers => [{<<"x-a">>, <<"1">>}]
    }),
    Req1 = livery_req:append_header(<<"X-A">>, <<"2">>, Req0),
    ?assertEqual([<<"1">>, <<"2">>], livery_req:headers_all(<<"x-a">>, Req1)).

delete_header_removes_every_occurrence_test() ->
    Req0 = livery_req:new(#{
        protocol => h1, method => <<"GET">>, path => <<"/">>,
        headers => [{<<"x-a">>, <<"1">>}, {<<"x-a">>, <<"2">>}, {<<"x-b">>, <<"3">>}]
    }),
    Req1 = livery_req:delete_header(<<"X-A">>, Req0),
    ?assertEqual([{<<"x-b">>, <<"3">>}], livery_req:headers(Req1)).

bindings_are_map_based_test() ->
    Req0 = livery_req:new(#{
        protocol => h1, method => <<"GET">>, path => <<"/u/1">>
    }),
    Req1 = livery_req:set_bindings(#{<<"id">> => <<"1">>}, Req0),
    ?assertEqual(<<"1">>, livery_req:binding(<<"id">>, Req1)),
    ?assertEqual(undefined, livery_req:binding(<<"missing">>, Req1)),
    ?assertEqual(<<"d">>, livery_req:binding(<<"missing">>, Req1, <<"d">>)).

meta_is_namespaced_by_module_test() ->
    Req0 = livery_req:new(#{
        protocol => h1, method => <<"GET">>, path => <<"/">>
    }),
    Req1 = livery_req:set_meta(trace_id, <<"abc">>, Req0),
    Req2 = livery_req:set_meta(trace_id, <<"def">>, Req1),
    ?assertEqual(<<"def">>, livery_req:meta(trace_id, Req2)),
    ?assertEqual(undefined, livery_req:meta(missing, Req2)),
    ?assertEqual(<<"d">>, livery_req:meta(missing, Req2, <<"d">>)).

body_is_opaque_to_req_test() ->
    Req0 = livery_req:new(#{
        protocol => h1, method => <<"POST">>, path => <<"/">>,
        body => {buffered, <<"hi">>}
    }),
    ?assertEqual({buffered, <<"hi">>}, livery_req:body(Req0)),
    Req1 = livery_req:set_body({stream, make_ref()}, Req0),
    ?assertMatch({stream, _}, livery_req:body(Req1)).
