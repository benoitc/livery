-module(livery_a2a_tests).

-include_lib("eunit/include/eunit.hrl").
-include("livery.hrl").

-compile([export_all, nowarn_export_all]).

-define(CARD, <<"/.well-known/agent-card.json">>).

%% Other EUnit modules start livery_req_sup themselves, so leave the
%% applications as they were found.
with_server(Fun) ->
    {ok, Started} = application:ensure_all_started([livery, barrel_a2a]),
    {ok, Server} = barrel_a2a_server:start(livery_a2a_test_agent:card(), #{
        handler => livery_a2a_test_agent,
        listen => false,
        auth => none,
        url => <<"http://agent.test">>
    }),
    try
        Fun(Server)
    after
        barrel_a2a_server:stop(Server),
        lists:foreach(fun application:stop/1, lists:reverse(Started))
    end.

%% The mount goes to the engine whole: every declared route, any
%% method, and any path under the base. Only what is outside the mount
%% is livery's.
router_sends_the_mount_to_the_engine_test() ->
    with_server(fun(Server) ->
        Router = livery_a2a:router(Server),
        Reaches = [
            {<<"GET">>, ?CARD},
            {<<"HEAD">>, ?CARD},
            {<<"POST">>, ?CARD},
            {<<"POST">>, <<"/a2a/jsonrpc">>},
            {<<"DELETE">>, <<"/a2a/jsonrpc">>},
            {<<"POST">>, <<"/a2a/v1/message:send">>},
            {<<"POST">>, <<"/a2a/v1/message:stream">>},
            {<<"GET">>, <<"/a2a/v1/tasks">>},
            {<<"GET">>, <<"/a2a/v1/tasks/abc">>},
            {<<"PUT">>, <<"/a2a/v1/tasks/abc">>},
            {<<"POST">>, <<"/a2a/v1/tasks/abc:cancel">>},
            {<<"POST">>, <<"/a2a/v1/tasks/abc:subscribe">>},
            {<<"GET">>, <<"/a2a/v1/tasks/abc/pushNotificationConfigs/c1">>},
            {<<"DELETE">>, <<"/a2a/v1/tasks/abc/pushNotificationConfigs/c1">>},
            %% Unknown paths inside the mount are the engine's to refuse.
            {<<"GET">>, <<"/a2a/v1/bogus">>},
            {<<"GET">>, <<"/a2a/nonsense/deep">>},
            {<<"GET">>, <<"/a2a">>}
        ],
        lists:foreach(
            fun({M, P}) ->
                ?assertMatch({ok, _, _, _}, livery_router:match(M, P, Router))
            end,
            Reaches
        ),
        ?assertMatch({error, not_found}, livery_router:match(<<"GET">>, <<"/nope">>, Router)),
        ?assertMatch({error, not_found}, livery_router:match(<<"GET">>, <<"/a2ax">>, Router))
    end).

%% A route of your own under the prefix still wins: the router prefers
%% a literal segment to a wildcard.
router_merges_under_the_prefix_test() ->
    with_server(fun(Server) ->
        Mine = fun(_Req) -> livery_resp:text(200, <<"mine">>) end,
        Router = livery_router:merge(
            livery_router:compile([{<<"GET">>, <<"/a2a/mine">>, Mine}]),
            livery_a2a:router(Server)
        ),
        {ok, Mine1, _, _} = livery_router:match(<<"GET">>, <<"/a2a/mine">>, Router),
        ?assertMatch(#livery_resp{body = {full, <<"mine">>}}, Mine1(undefined)),
        ?assertMatch({ok, _, _, _}, livery_router:match(<<"POST">>, <<"/a2a/jsonrpc">>, Router))
    end).

bad_option_raises_test() ->
    with_server(fun(Server) ->
        ?assertError(
            {invalid_engine_option, keepalive_ms, bad},
            livery_a2a:router(Server, #{keepalive_ms => bad})
        )
    end).

serve_with_fake_stream_test() ->
    with_server(fun(Server) ->
        Handler = livery_a2a:handler(barrel_a2a_server:engine_config(Server, #{})),
        Tab = livery_test_adapter:start(),
        try
            %% JSON-RPC message/send over a buffered body.
            Body = barrel_a2a_json:encode(#{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => 1,
                <<"method">> => <<"SendMessage">>,
                <<"params">> => #{<<"message">> => barrel_a2a_message:new(<<"echo: fake">>)}
            }),
            Cap = run(Tab, Handler, #{
                method => <<"POST">>,
                path => <<"/a2a/jsonrpc">>,
                headers => [
                    {<<"content-type">>, <<"application/json">>},
                    {<<"a2a-version">>, <<"1.0">>}
                ],
                body => {buffered, Body}
            }),
            ?assertEqual(200, livery_test_adapter:status(Cap)),
            {ok, #{<<"result">> := #{<<"task">> := Task}}} =
                barrel_a2a_json:decode(livery_test_adapter:body(Cap)),
            ?assertEqual(completed, barrel_a2a_task:state(Task)),
            ?assertEqual(
                <<"fake">>, barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Task)))
            ),
            %% REST GET with a query string: historyLength=0 trims history.
            Id = barrel_a2a_task:id(Task),
            Cap2 = run(Tab, Handler, #{
                method => <<"GET">>,
                path => <<"/a2a/v1/tasks/", Id/binary>>,
                raw_query => <<"historyLength=0">>,
                headers => [{<<"a2a-version">>, <<"1.0">>}]
            }),
            ?assertEqual(200, livery_test_adapter:status(Cap2)),
            {ok, Fetched} = barrel_a2a_json:decode(livery_test_adapter:body(Cap2)),
            ?assertEqual([], barrel_a2a_task:history(Fetched)),
            %% The card, and HEAD on it.
            Cap3 = run(Tab, Handler, #{method => <<"GET">>, path => ?CARD}),
            ?assertEqual(200, livery_test_adapter:status(Cap3)),
            {ok, Card} = barrel_a2a_json:decode(livery_test_adapter:body(Cap3)),
            ?assertEqual(<<"Test Agent">>, maps:get(<<"name">>, Card)),
            Cap4 = run(Tab, Handler, #{method => <<"HEAD">>, path => ?CARD}),
            ?assertEqual(200, livery_test_adapter:status(Cap4)),
            ?assertEqual(<<>>, livery_test_adapter:body(Cap4))
        after
            livery_test_adapter:stop(Tab)
        end
    end).

%% The handler writes through the adapter itself, so the request is
%% built by hand rather than through livery_test_adapter:run/3.
run(Tab, Handler, Spec) ->
    Stream = livery_test_adapter:new_stream(Tab),
    Req = livery_req:new(Spec#{adapter => livery_test_adapter, stream => Stream}),
    #livery_resp{body = taken_over} = Handler(Req),
    livery_test_adapter:capture(Stream).
