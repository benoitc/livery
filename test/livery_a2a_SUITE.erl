%% End-to-end: a barrel_a2a server without a listener, mounted on a
%% livery service through livery_a2a, driven by barrel_a2a_client over
%% both HTTP bindings.
-module(livery_a2a_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2, init_per_testcase/2, end_per_testcase/2]).
-export([
    discovery/1,
    send/1,
    streaming/1,
    input_required_follow_up/1,
    cancel/1,
    query_string_reaches_engine/1,
    not_found_and_method_not_allowed/1,
    disconnect_mid_stream/1,
    auth_via_livery/1,
    nested_prefix/1
]).
%% livery middleware and logger handler callbacks used by the suite
-export([call/3, log/2]).

all() ->
    [
        {group, jsonrpc},
        {group, rest},
        not_found_and_method_not_allowed,
        disconnect_mid_stream,
        auth_via_livery,
        nested_prefix
    ].

groups() ->
    Cases = [
        discovery, send, streaming, input_required_follow_up, cancel, query_string_reaches_engine
    ],
    [{jsonrpc, [], Cases}, {rest, [], Cases}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(barrel_a2a),
    {ok, _} = application:ensure_all_started(hackney),
    Stack = start_stack(#{}, fun(Server) ->
        livery_router:layer([{?MODULE, livery_a2a_test_sink}], livery_a2a:router(Server))
    end),
    [{stack, Stack} | Config].

end_per_suite(Config) ->
    stop_stack(?config(stack, Config)).

init_per_group(Group, Config) ->
    [{prefer, [Group]} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    catch unregister(livery_a2a_test_sink),
    register(livery_a2a_test_sink, self()),
    Config.

end_per_testcase(_Case, _Config) ->
    catch unregister(livery_a2a_test_sink),
    ok.

%%--------------------------------------------------------------------
%% Stack helpers
%%--------------------------------------------------------------------

%% Starts a barrel_a2a server with no listener, a livery H1 service on
%% an ephemeral port serving RouterFun(Server), then rewrites the card
%% so its interfaces point at the bound port.
start_stack(ServerOpts, RouterFun) ->
    Base = maps:get(base_path, ServerOpts, <<"/a2a">>),
    {ok, Server} = barrel_a2a_server:start(
        livery_a2a_test_agent:card(),
        maps:merge(
            #{
                handler => livery_a2a_test_agent,
                listen => false,
                auth => none,
                blocking_timeout => 5000,
                url => <<"http://127.0.0.1">>
            },
            ServerOpts
        )
    ),
    {ok, Service} = livery:start_service(#{
        http => #{port => 0},
        router => RouterFun(Server)
    }),
    true = unlink(Service),
    #{h1 := [Port | _]} = livery:which_listeners(Service),
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
    V = barrel_a2a:protocol_version(),
    Card = barrel_a2a_agent_card:with_interfaces(
        [
            barrel_a2a_agent_card:interface(
                <<Url/binary, Base/binary, "/jsonrpc">>, barrel_a2a:binding_jsonrpc(), V
            ),
            barrel_a2a_agent_card:interface(
                <<Url/binary, Base/binary, "/v1">>, barrel_a2a:binding_rest(), V
            )
        ],
        livery_a2a_test_agent:card()
    ),
    ok = barrel_a2a_server:update_card(Server, Card),
    #{server => Server, service => Service, port => Port, url => Url, base => Base}.

stop_stack(#{server := Server, service := Service}) ->
    catch livery:stop_service(Service),
    catch barrel_a2a_server:stop(Server),
    ok.

connect(Config) ->
    connect(?config(stack, Config), #{prefer => ?config(prefer, Config)}).

connect(#{url := Url}, Opts) ->
    {ok, Agent} = barrel_a2a_client:connect(Url, Opts#{timeout => 5000}),
    Agent.

url(Config, Path) ->
    #{url := Url} = ?config(stack, Config),
    <<Url/binary, Path/binary>>.

%% Route middleware: tells the test process (registered as the sink)
%% which worker serves the request, so disconnect_mid_stream can watch
%% it exit.
call(Req, Next, Sink) ->
    case whereis(Sink) of
        undefined -> ok;
        Pid -> Pid ! {worker, self(), livery_req:path(Req)}
    end,
    Next(Req).

%%--------------------------------------------------------------------
%% Binding-parametrised cases
%%--------------------------------------------------------------------

discovery(Config) ->
    Agent = connect(Config),
    Card = barrel_a2a_client:card(Agent),
    ?assertEqual(<<"Test Agent">>, maps:get(<<"name">>, Card)),
    ?assertEqual([<<"echo">>], [maps:get(<<"id">>, S) || S <- barrel_a2a_client:skills(Agent)]),
    Expected =
        case ?config(prefer, Config) of
            [jsonrpc] -> barrel_a2a:binding_jsonrpc();
            [rest] -> barrel_a2a:binding_rest()
        end,
    ?assertEqual(Expected, barrel_a2a_client:binding(Agent)).

send(Config) ->
    Agent = connect(Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"echo: hello">>),
    ?assertEqual(completed, barrel_a2a_task:state(Task)),
    [A] = barrel_a2a_task:artifacts(Task),
    ?assertEqual(<<"hello">>, barrel_a2a_artifact:text(A)),
    {ok, Fetched} = barrel_a2a_client:get_task(Agent, barrel_a2a_task:id(Task)),
    ?assertEqual(barrel_a2a_task:id(Task), barrel_a2a_task:id(Fetched)).

streaming(Config) ->
    Agent = connect(Config),
    {ok, RT} = barrel_a2a_client:start(Agent, <<"stream">>),
    ok = barrel_a2a_remote_task:stream_to(RT, self()),
    {Events, {done, Final}} = collect_events(RT),
    ?assertEqual(
        [task, status_update, artifact_update, artifact_update, status_update],
        [barrel_a2a_event:kind(E) || E <- Events]
    ),
    ?assertEqual(completed, barrel_a2a_task:state(Final)),
    ?assertEqual(<<"part one part two">>, barrel_a2a_remote_task:text(RT)),
    {ok, Result} = barrel_a2a_remote_task:result(RT, 1000),
    ?assertEqual(completed, barrel_a2a_task:state(Result)).

input_required_follow_up(Config) ->
    Agent = connect(Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"ask">>),
    ?assertEqual(input_required, barrel_a2a_task:state(Task)),
    ?assertEqual(<<"more?">>, barrel_a2a_message:text(barrel_a2a_task:status_message(Task))),
    {ok, {task, Done}} = barrel_a2a_client:send(Agent, <<"here you go">>, #{
        task_id => barrel_a2a_task:id(Task),
        context_id => barrel_a2a_task:context_id(Task)
    }),
    ?assertEqual(completed, barrel_a2a_task:state(Done)),
    ?assertEqual(
        <<"thanks: here you go">>,
        barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Done)))
    ).

cancel(Config) ->
    Agent = connect(Config),
    {ok, RT} = barrel_a2a_client:start(Agent, <<"cancel-me">>),
    ok = barrel_a2a_remote_task:stream_to(RT, self()),
    receive
        {a2a_event, RT, #{
            <<"statusUpdate">> := #{<<"status">> := #{<<"state">> := <<"TASK_STATE_WORKING">>}}
        }} ->
            ok
    after 5000 -> ct:fail(no_working_event)
    end,
    {ok, Task} = barrel_a2a_remote_task:cancel(RT),
    ?assertEqual(canceled, barrel_a2a_task:state(Task)),
    ?assertMatch({_, {done, _}}, collect_events(RT)),
    receive
        handle_cancel_called -> ok
    after 2000 -> ct:fail(handle_cancel_not_called)
    end.

query_string_reaches_engine(Config) ->
    Agent = connect(Config),
    {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"echo: q">>),
    Id = barrel_a2a_task:id(Task),
    ?assert(length(barrel_a2a_task:history(Task)) > 0),
    {ok, Trimmed} = barrel_a2a_client:get_task(Agent, Id, #{history_length => 0}),
    ?assertEqual([], barrel_a2a_task:history(Trimmed)).

%%--------------------------------------------------------------------
%% Router integration
%%--------------------------------------------------------------------

not_found_and_method_not_allowed(Config) ->
    %% Outside the mount: livery's own 404, as text.
    {ok, 404, _, Text} = hackney:request(get, url(Config, <<"/nope">>), [], <<>>, [with_body]),
    ?assertEqual(<<"not found">>, Text),
    %% Inside the mount every 404 and 405 is the engine's, as an A2A
    %% error object. An unknown path:
    {ok, 404, Hs1, Body1} = get_(Config, <<"/a2a/v1/bogus">>),
    ?assertEqual(<<"application/a2a+json">>, header(<<"content-type">>, Hs1)),
    ?assertNotEqual(nomatch, binary:match(Body1, <<"No such route">>)),
    %% A known path reached with a method it does not serve. The Allow
    %% names the methods serving that path, not the ones livery holds
    %% for the pattern, which is why the whole mount goes to the engine.
    {ok, 405, Hs2, _} = delete_(Config, <<"/a2a/v1/tasks/abc">>),
    ?assertEqual(<<"GET">>, header(<<"allow">>, Hs2)),
    ?assertEqual(<<"application/a2a+json">>, header(<<"content-type">>, Hs2)),
    {ok, 405, Hs3, _} = delete_(Config, <<"/a2a/jsonrpc">>),
    ?assertEqual(<<"POST">>, header(<<"allow">>, Hs3)),
    %% A custom verb the engine does not know is its 404, and one it
    %% does, reached with the wrong method, its 405 naming the method
    %% that serves the verb.
    {ok, 404, _, Body4} = post_(Config, <<"/a2a/v1/tasks/x:frobnicate">>),
    ?assertNotEqual(nomatch, binary:match(Body4, <<"No such route">>)),
    {ok, 405, Hs5, _} = get_(Config, <<"/a2a/v1/tasks/x:cancel">>),
    ?assertEqual(<<"POST">>, header(<<"allow">>, Hs5)),
    %% Verb routes still reach the engine: unknown task, not unknown route.
    {ok, 404, _, Body6} = post_(Config, <<"/a2a/v1/tasks/x:cancel">>),
    ?assertNotEqual(nomatch, binary:match(Body6, <<"TASK_NOT_FOUND">>)).

%% The client drops the connection while the agent is still working:
%% the worker running the engine loop must exit, and nothing gets
%% logged at error level.
disconnect_mid_stream(Config) ->
    #{port := Port} = ?config(stack, Config),
    flush_workers(),
    HandlerId = a2a_disconnect_log,
    ok = logger:add_handler(HandlerId, ?MODULE, #{config => self(), level => all}),
    try
        ReqBody = barrel_a2a_json:encode(#{
            <<"message">> => barrel_a2a_message:new(<<"slow 1500">>)
        }),
        Raw = [
            <<"POST /a2a/v1/message:stream HTTP/1.1\r\n">>,
            <<"Host: x\r\n">>,
            <<"Content-Type: application/json\r\n">>,
            <<"Accept: text/event-stream\r\n">>,
            <<"A2A-Version: 1.0\r\n">>,
            <<"Content-Length: ">>,
            integer_to_binary(iolist_size(ReqBody)),
            <<"\r\n\r\n">>,
            ReqBody
        ],
        {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000),
        ok = gen_tcp:send(Sock, Raw),
        Worker =
            receive
                {worker, Pid, <<"/a2a/v1/message:stream">>} -> Pid
            after 5000 -> ct:fail(no_worker)
            end,
        %% The stream is open: headers and the task snapshot arrive.
        {ok, First} = gen_tcp:recv(Sock, 0, 5000),
        ?assertNotEqual(nomatch, binary:match(First, <<"200">>)),
        Mon = monitor(process, Worker),
        ok = gen_tcp:close(Sock),
        receive
            {'DOWN', Mon, process, Worker, _} -> ok
        after 3000 -> ct:fail(worker_still_running)
        end,
        %% The agent finishes on its own after the peer left.
        timer:sleep(1500),
        ok = assert_no_error_logged(),
        %% The service is still healthy.
        {ok, 200, _, _} = hackney:request(
            get, url(Config, <<"/.well-known/agent-card.json">>), [], <<>>, []
        )
    after
        logger:remove_handler(HandlerId)
    end.

%% Auth is livery middleware: the bearer claims become the A2A
%% principal, and an anonymous request is refused by livery, not by
%% barrel_a2a (whose hook is `none' here).
auth_via_livery(_Config) ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(
        Key,
        #{<<"kid">> => <<"rsa-1">>},
        #{<<"sub">> => <<"alice">>, <<"exp">> => os:system_time(second) + 3600}
    ),
    Stack = start_stack(#{}, fun(Server) ->
        livery_router:layer([{livery_auth_bearer, #{keys => [Jwk]}}], livery_a2a:router(Server))
    end),
    try
        Agent = connect(Stack, #{prefer => [jsonrpc], auth => {bearer, Token}}),
        {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"principal">>),
        Text = barrel_a2a_artifact:text(hd(barrel_a2a_task:artifacts(Task))),
        ?assertNotEqual(nomatch, binary:match(Text, <<"alice">>)),
        #{url := Url} = Stack,
        ?assertMatch({error, _}, barrel_a2a_client:connect(Url, #{prefer => [jsonrpc]})),
        {ok, 401, _, _} = hackney:request(
            get, <<Url/binary, "/.well-known/agent-card.json">>, [], <<>>, []
        )
    after
        stop_stack(Stack)
    end.

%% The agent lives under a prefix next to other routes; the card stays
%% at the well-known path and the default base path is gone.
nested_prefix(_Config) ->
    Base = <<"/agents/echo/a2a">>,
    Health = fun(_Req) -> livery_resp:text(200, <<"ok">>) end,
    Stack = start_stack(#{base_path => Base}, fun(Server) ->
        livery_router:merge(
            livery_router:compile([{<<"GET">>, <<"/health">>, Health}]),
            livery_a2a:router(Server, #{base_path => Base})
        )
    end),
    try
        #{url := Url} = Stack,
        Agent = connect(Stack, #{prefer => [rest]}),
        [If | _] = barrel_a2a_agent_card:interfaces(barrel_a2a_client:card(Agent)),
        ?assertNotEqual(nomatch, binary:match(maps:get(<<"url">>, If), Base)),
        {ok, {task, Task}} = barrel_a2a_client:send(Agent, <<"echo: nested">>),
        ?assertEqual(completed, barrel_a2a_task:state(Task)),
        {ok, 200, _, _} = hackney:request(get, <<Url/binary, "/health">>, [], <<>>, []),
        {ok, 404, _, _} = hackney:request(
            post, <<Url/binary, "/a2a/jsonrpc">>, json_headers(), <<"{}">>, []
        )
    after
        stop_stack(Stack)
    end.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

json_headers() ->
    [{<<"a2a-version">>, <<"1.0">>}, {<<"content-type">>, <<"application/json">>}].

get_(Config, Path) ->
    hackney:request(get, url(Config, Path), json_headers(), <<>>, [with_body]).

delete_(Config, Path) ->
    hackney:request(delete, url(Config, Path), json_headers(), <<>>, [with_body]).

post_(Config, Path) ->
    hackney:request(post, url(Config, Path), json_headers(), <<"{}">>, [with_body]).

header(Name, Headers) ->
    proplists:get_value(Name, [{string:lowercase(K), V} || {K, V} <- Headers], <<>>).

collect_events(RT) -> collect_events(RT, []).

collect_events(RT, Acc) ->
    receive
        {a2a_event, RT, Ev} -> collect_events(RT, [Ev | Acc]);
        {a2a_done, RT, Final} -> {lists:reverse(Acc), {done, Final}};
        {a2a_error, RT, E} -> {lists:reverse(Acc), {error, E}}
    after 10000 -> {lists:reverse(Acc), timeout}
    end.

flush_workers() ->
    receive
        {worker, _, _} -> flush_workers()
    after 0 -> ok
    end.

%% logger handler callback: forward error-level events to the test.
log(#{level := Level} = Event, #{config := Pid}) when Level =:= error; Level =:= critical ->
    Pid ! {logged, Event};
log(_Event, _Config) ->
    ok.

assert_no_error_logged() ->
    receive
        {logged, Event} -> ct:fail({error_logged, Event})
    after 0 -> ok
    end.
