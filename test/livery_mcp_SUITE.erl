%% @doc End-to-end MCP Streamable HTTP suite.
%%
%% Mounts `livery_mcp:handler/1' on a Livery H1 listener and drives a
%% real MCP session (initialize, notifications/initialized,
%% tools/list, tools/call) with hackney, asserting the JSON-RPC
%% responses and the `Mcp-Session-Id' header. Proves the Livery
%% adapter <-> barrel_mcp engine bridge end to end.
-module(livery_mcp_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    initialize_returns_session/1,
    tools_list_returns_registered_tool/1,
    tools_call_runs_tool/1,
    disconnect_mid_reply_is_quiet/1,
    modern_cancel_stops_the_tool/1,
    get_stream_ends_when_client_leaves/1,
    finished_call_gets_no_disconnect/1,
    initialize_carries_instructions/1,
    oversized_body_is_413/1
]).

%% Tool callbacks (registered in init_per_suite).
-export([echo_tool/1, slow_tool/1, waiting_tool/2]).

%% logger handler callback (used by disconnect_mid_reply_is_quiet).
-export([log/2]).

%% The case a tool reports to.
-define(WATCH, livery_mcp_watch).

all() ->
    [
        initialize_returns_session,
        tools_list_returns_registered_tool,
        tools_call_runs_tool,
        disconnect_mid_reply_is_quiet,
        modern_cancel_stops_the_tool,
        get_stream_ends_when_client_leaves,
        finished_call_gets_no_disconnect,
        initialize_carries_instructions,
        oversized_body_is_413
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(h1),
    {ok, _} = application:ensure_all_started(hackney),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_tool(<<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echo the value back">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"value">> => #{<<"type">> => <<"string">>}
            }
        }
    }),
    ok = barrel_mcp:reg_tool(<<"slow">>, ?MODULE, slow_tool, #{
        description => <<"Sleeps then replies">>,
        input_schema => #{<<"type">> => <<"object">>, <<"properties">> => #{}}
    }),
    ok = barrel_mcp:reg_tool(<<"waiting">>, ?MODULE, waiting_tool, #{
        description => <<"Waits to be cancelled">>,
        input_schema => #{<<"type">> => <<"object">>, <<"properties">> => #{}}
    }),
    Config.

end_per_suite(_Config) ->
    catch barrel_mcp:unreg_tool(<<"waiting">>),
    catch barrel_mcp:unreg_tool(<<"echo">>),
    catch barrel_mcp:unreg_tool(<<"slow">>),
    _ = application:stop(hackney),
    ok.

%% The h1 listener is started per testcase so it is owned by the same
%% process that drives the requests.
init_per_testcase(_TC, Config) ->
    {ok, Listener} = livery_h1:start(#{
        port => 0,
        stack => [],
        handler => livery_mcp:handler(#{session_enabled => true})
    }),
    Port = h1:server_port(Listener),
    Url = iolist_to_binary([
        <<"http://127.0.0.1:">>,
        integer_to_binary(Port),
        <<"/mcp">>
    ]),
    [{listener, Listener}, {url, Url} | Config].

end_per_testcase(_TC, Config) ->
    catch livery_h1:stop(?config(listener, Config)),
    ok.

%% Tool callback: returns a binary, echoed back as the result text.
echo_tool(Args) ->
    Value = maps:get(<<"value">>, Args, <<"default">>),
    <<"echo: ", Value/binary>>.

%% Tool callback: sleeps so the client can disconnect before the reply.
slow_tool(_Args) ->
    timer:sleep(300),
    <<"slow done">>.

%% Tool callback: tells the case it runs, then waits to be cancelled. Its
%% side effect is the `tool_finished' message.
waiting_tool(_Args, Ctx) ->
    ?WATCH ! {tool_started, self(), maps:get(request_id, Ctx)},
    receive
        {cancel, Id} -> ?WATCH ! {tool_cancelled, Id}
    after 3000 -> ?WATCH ! tool_finished
    end,
    <<"waited">>.

%%====================================================================
%% Cases
%%====================================================================

initialize_returns_session(Config) ->
    {Status, Headers, Body} = initialize(?config(url, Config)),
    ?assertEqual(200, Status),
    Resp = json:decode(Body),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Resp)),
    Result = maps:get(<<"result">>, Resp),
    ?assert(maps:is_key(<<"protocolVersion">>, Result)),
    ?assertNotEqual(undefined, session_id(Headers)).

tools_list_returns_registered_tool(Config) ->
    Url = ?config(url, Config),
    {200, Headers, _} = initialize(Url),
    Sid = session_id(Headers),
    ok = initialized(Url, Sid),
    Body = post(Url, Sid, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 2,
        <<"method">> => <<"tools/list">>,
        <<"params">> => #{}
    }),
    Resp = json:decode(Body),
    Tools = maps:get(<<"tools">>, maps:get(<<"result">>, Resp)),
    Names = [maps:get(<<"name">>, T) || T <- Tools],
    ?assert(lists:member(<<"echo">>, Names)).

tools_call_runs_tool(Config) ->
    Url = ?config(url, Config),
    {200, Headers, _} = initialize(Url),
    Sid = session_id(Headers),
    ok = initialized(Url, Sid),
    Body = post(Url, Sid, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 3,
        <<"method">> => <<"tools/call">>,
        <<"params">> => #{
            <<"name">> => <<"echo">>,
            <<"arguments">> => #{<<"value">> => <<"hi">>}
        }
    }),
    %% barrel_mcp 3.0 answers a legacy tools/call as an SSE stream when
    %% Accept lists text/event-stream; the result is the final event.
    Resp = last_sse_event(Body),
    ?assertEqual(3, maps:get(<<"id">>, Resp)),
    ?assert(not maps:is_key(<<"error">>, Resp)),
    Content = maps:get(<<"content">>, maps:get(<<"result">>, Resp)),
    Texts = [
        maps:get(<<"text">>, C)
     || C <- Content,
        maps:get(<<"type">>, C) =:= <<"text">>
    ],
    Joined = iolist_to_binary(Texts),
    ?assertNotEqual(nomatch, binary:match(Joined, <<"echo: hi">>)).

%% The client closes before the slow tool's reply is written. The MCP
%% responder writes into the now-dead connection: that must end the
%% request quietly (no ERROR/CRASH log), and the server must stay healthy.
disconnect_mid_reply_is_quiet(Config) ->
    Url = ?config(url, Config),
    Port = h1:server_port(?config(listener, Config)),
    {200, Headers, _} = initialize(Url),
    Sid = session_id(Headers),
    ok = initialized(Url, Sid),
    HandlerId = mcp_disconnect_log,
    ok = logger:add_handler(HandlerId, ?MODULE, #{config => self(), level => all}),
    try
        ReqBody = iolist_to_binary(
            json:encode(#{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => 9,
                <<"method">> => <<"tools/call">>,
                <<"params">> => #{<<"name">> => <<"slow">>, <<"arguments">> => #{}}
            })
        ),
        Raw = [
            <<"POST /mcp HTTP/1.1\r\n">>,
            <<"Host: x\r\n">>,
            <<"Content-Type: application/json\r\n">>,
            <<"Accept: application/json, text/event-stream\r\n">>,
            <<"Mcp-Session-Id: ">>,
            Sid,
            <<"\r\n">>,
            <<"Content-Length: ">>,
            integer_to_binary(byte_size(ReqBody)),
            <<"\r\n\r\n">>,
            ReqBody
        ],
        {ok, Sock} = gen_tcp:connect(
            "127.0.0.1", Port, [binary, {active, false}], 5000
        ),
        ok = gen_tcp:send(Sock, Raw),
        timer:sleep(50),
        ok = gen_tcp:close(Sock),
        %% Let the slow tool finish and the responder write into the dead conn.
        timer:sleep(600),
        ok = assert_no_error_logged(),
        %% Server is still healthy: a fresh session initializes.
        ?assertMatch({200, _, _}, initialize(Url))
    after
        logger:remove_handler(HandlerId)
    end.

%% "MUST treat a client disconnect as cancellation of that request"
%% (MCP 2026-07-28, basic/patterns/cancellation). A modern client cancels
%% by closing the request's stream, so the engine has to hear about it.
modern_cancel_stops_the_tool(_Config) ->
    {ok, Service} = livery:start_service(#{http => #{port => 0}, router => livery_mcp:router()}),
    true = unlink(Service),
    #{h1 := [Port | _]} = livery:which_listeners(Service),
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/mcp">>,
    true = register(?WATCH, self()),
    {ok, Client} = barrel_mcp_client:start(#{transport => {http, Url}}),
    try
        ok = wait_until(fun() -> client_ready(Client) end, 8000),
        ?assertEqual({ok, <<"2026-07-28">>}, barrel_mcp_client:protocol_version(Client)),
        Self = self(),
        _ = spawn_link(fun() ->
            Self ! {call_result, barrel_mcp_client:call_tool(Client, <<"waiting">>, #{})}
        end),
        {Tool, RequestId} =
            receive
                {tool_started, Pid, Id} -> {Pid, Id}
            after 5000 -> ct:fail(tool_did_not_start)
            end,
        MRef = erlang:monitor(process, Tool),
        ok = barrel_mcp_client:cancel(Client, RequestId),
        receive
            {call_result, Result} -> ?assertEqual({error, cancelled}, Result)
        after 5000 -> ct:fail(call_not_cancelled)
        end,
        %% The tool is told, well before its own 3 s wait is over, and
        %% stops on its own instead of being killed.
        receive
            {tool_cancelled, CancelledId} -> ?assertEqual(RequestId, CancelledId)
        after 2000 -> ct:fail(tool_not_told)
        end,
        receive
            {'DOWN', MRef, process, Tool, Reason} -> ?assertNotEqual(killed, Reason)
        after 2000 -> ct:fail(tool_still_running)
        end,
        receive
            tool_finished -> ct:fail(tool_finished_after_cancel)
        after 0 -> ok
        end
    after
        catch barrel_mcp_client:close(Client),
        unregister(?WATCH),
        catch livery:stop_service(Service)
    end.

%% The standalone GET stream is long-lived: when its client goes away
%% the request must end, not wait for the next keepalive write to fail.
get_stream_ends_when_client_leaves(Config) ->
    Url = ?config(url, Config),
    Port = h1:server_port(?config(listener, Config)),
    {200, Headers, _} = initialize(Url),
    Sid = session_id(Headers),
    ok = initialized(Url, Sid),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Sock, [
        <<"GET /mcp HTTP/1.1\r\nHost: x\r\nAccept: text/event-stream\r\n">>,
        <<"Mcp-Session-Id: ">>,
        Sid,
        <<"\r\n\r\n">>
    ]),
    ok = wait_until(
        fun() -> element(1, barrel_mcp_session:get_sse_pid(Sid)) =:= ok end, 5000
    ),
    {ok, Stream} = barrel_mcp_session:get_sse_pid(Sid),
    MRef = erlang:monitor(process, Stream),
    ok = gen_tcp:close(Sock),
    receive
        {'DOWN', MRef, process, Stream, _} -> ok
    after 2000 -> ct:fail(stream_outlived_its_client)
    end.

%% The relay is only for a client that leaves mid-request. A call that
%% was answered must not see `mcp_disconnect' when its connection closes
%% afterwards.
finished_call_gets_no_disconnect(Config) ->
    Url = ?config(url, Config),
    Port = h1:server_port(?config(listener, Config)),
    {200, Headers, _} = initialize(Url),
    Sid = session_id(Headers),
    ok = initialized(Url, Sid),
    ReqBody = iolist_to_binary(
        json:encode(#{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 4,
            <<"method">> => <<"tools/call">>,
            <<"params">> => #{
                <<"name">> => <<"echo">>, <<"arguments">> => #{<<"value">> => <<"hi">>}
            }
        })
    ),
    1 = erlang:trace_pattern('receive', [{['_', '_', mcp_disconnect], [], []}], []),
    _ = erlang:trace(new_processes, true, ['receive']),
    try
        {ok, Sock} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000),
        ok = gen_tcp:send(Sock, [
            <<"POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n">>,
            <<"Accept: application/json, text/event-stream\r\nMcp-Session-Id: ">>,
            Sid,
            <<"\r\nContent-Length: ">>,
            integer_to_binary(byte_size(ReqBody)),
            <<"\r\n\r\n">>,
            ReqBody
        ]),
        Answer = recv_until(Sock, <<"echo: hi">>, <<>>),
        ?assertNotEqual(nomatch, binary:match(Answer, <<"echo: hi">>)),
        timer:sleep(100),
        ok = gen_tcp:close(Sock),
        receive
            {trace, Pid, 'receive', mcp_disconnect} -> ct:fail({disconnect_after_finish, Pid})
        after 500 -> ok
        end
    after
        _ = erlang:trace(new_processes, false, ['receive']),
        _ = erlang:trace_pattern('receive', true, [])
    end.

initialize_carries_instructions(Config) ->
    ok = application:set_env(barrel_mcp, instructions, <<"Call echo to test.">>),
    try
        {200, _, Body} = initialize(?config(url, Config)),
        Result = maps:get(<<"result">>, json:decode(Body)),
        ?assertEqual(<<"Call echo to test.">>, maps:get(<<"instructions">>, Result))
    after
        application:unset_env(barrel_mcp, instructions)
    end.

%% A body past `max_body_bytes' is refused before the engine sees it.
oversized_body_is_413(_Config) ->
    {ok, Listener} = livery_h1:start(#{
        port => 0,
        stack => [],
        handler => livery_mcp:handler(#{max_body_bytes => 64})
    }),
    try
        Url = iolist_to_binary([
            <<"http://127.0.0.1:">>,
            integer_to_binary(h1:server_port(Listener)),
            <<"/mcp">>
        ]),
        {Status, _, _} = initialize(Url),
        ?assertEqual(413, Status)
    after
        livery_h1:stop(Listener)
    end.

%%====================================================================
%% MCP client helpers (hackney)
%%====================================================================

initialize(Url) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2025-11-25">>,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{
                <<"name">> => <<"livery-test">>,
                <<"version">> => <<"1.0">>
            }
        }
    }),
    {ok, Status, Headers, RespBody} = hackney:request(
        post,
        Url,
        json_headers(),
        Body,
        [with_body, {recv_timeout, 5000}]
    ),
    {Status, Headers, RespBody}.

initialized(Url, Sid) ->
    Note = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/initialized">>
    }),
    {ok, _Status, _H, _B} = hackney:request(
        post,
        Url,
        with_session(json_headers(), Sid),
        Note,
        [with_body, {recv_timeout, 5000}]
    ),
    ok.

post(Url, Sid, Map) ->
    Body = json:encode(Map),
    {ok, 200, _Headers, RespBody} = hackney:request(
        post,
        Url,
        with_session(json_headers(), Sid),
        Body,
        [with_body, {recv_timeout, 5000}]
    ),
    RespBody.

json_headers() ->
    [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json, text/event-stream">>}
    ].

with_session(Headers, undefined) -> Headers;
with_session(Headers, Sid) -> [{<<"mcp-session-id">>, Sid} | Headers].

wait_until(Fun, Timeout) when Timeout =< 0 ->
    case Fun() of
        true -> ok;
        false -> timeout
    end;
wait_until(Fun, Timeout) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, Timeout - 50)
    end.

client_ready(Client) ->
    try barrel_mcp_client:protocol_version(Client) of
        {ok, _} -> true;
        _ -> false
    catch
        _:_ -> false
    end.

recv_until(Sock, Pattern, Acc) ->
    case binary:match(Acc, Pattern) of
        nomatch ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> recv_until(Sock, Pattern, <<Acc/binary, Data/binary>>);
                {error, _} -> Acc
            end;
        _ ->
            Acc
    end.

last_sse_event(Body) ->
    Datas = [
        Data
     || Line <- binary:split(Body, <<"\n">>, [global]),
        <<"data:", Data/binary>> <- [Line]
    ],
    json:decode(string:trim(lists:last(Datas))).

session_id(Headers) ->
    Lower = [{string:lowercase(K), V} || {K, V} <- Headers],
    proplists:get_value(<<"mcp-session-id">>, Lower, undefined).

%%====================================================================
%% Log capture (for disconnect_mid_reply_is_quiet)
%%====================================================================

log(Event, #{config := Pid}) ->
    Pid ! {log_event, Event},
    ok.

assert_no_error_logged() ->
    receive
        {log_event, #{level := error} = Event} ->
            ct:fail({unexpected_error_log, Event});
        {log_event, _Other} ->
            assert_no_error_logged()
    after 200 -> ok
    end.
