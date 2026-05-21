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
    tools_call_runs_tool/1
]).

%% Tool callback (registered in init_per_suite).
-export([echo_tool/1]).

all() ->
    [
        initialize_returns_session,
        tools_list_returns_registered_tool,
        tools_call_runs_tool
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
    Config.

end_per_suite(_Config) ->
    catch barrel_mcp:unreg_tool(<<"echo">>),
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
    Resp = json:decode(Body),
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

session_id(Headers) ->
    Lower = [{string:lowercase(K), V} || {K, V} <- Headers],
    proplists:get_value(<<"mcp-session-id">>, Lower, undefined).
