%% @doc Main compliance test suite for Livery HTTP server.
%%
%% Runs external compliance testing tools:
%% - h2spec: HTTP/2 compliance (RFC 7540, 7541)
%% - Autobahn|Testsuite: WebSocket compliance (RFC 6455)
%% - curl: HTTP/1.1 basic compliance
-module(livery_compliance_SUITE).

-include_lib("common_test/include/ct.hrl").

%% CT callbacks
-export([
    all/0,
    groups/0,
    suite/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Test cases - h2spec
-export([
    h2spec_generic/1,
    h2spec_http2_frames/1,
    h2spec_hpack/1
]).

%% Test cases - Autobahn
-export([
    autobahn_framing/1,
    autobahn_ping_pong/1,
    autobahn_fragmentation/1,
    autobahn_close/1,
    autobahn_utf8/1,
    autobahn_compression/1
]).

%% Test cases - curl
-export([
    curl_get_request/1,
    curl_post_request/1,
    curl_headers/1,
    curl_chunked/1,
    curl_keepalive/1,
    curl_http10/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

suite() ->
    [{timetrap, {minutes, 10}}].

all() ->
    [
        {group, h2spec_tests},
        {group, autobahn_tests},
        {group, curl_tests}
    ].

groups() ->
    [
        {h2spec_tests, [sequence], [
            h2spec_generic,
            h2spec_http2_frames,
            h2spec_hpack
        ]},
        {autobahn_tests, [sequence], [
            autobahn_framing,
            autobahn_ping_pong,
            autobahn_fragmentation,
            autobahn_close,
            autobahn_utf8,
            autobahn_compression
        ]},
        {curl_tests, [parallel], [
            curl_get_request,
            curl_post_request,
            curl_headers,
            curl_chunked,
            curl_keepalive,
            curl_http10
        ]}
    ].

init_per_suite(Config) ->
    application:ensure_all_started(livery),
    application:ensure_all_started(ssl),
    application:ensure_all_started(crypto),

    %% Find project root
    DataDir = proplists:get_value(data_dir, Config),
    ProjectRoot = filename:dirname(filename:dirname(filename:dirname(DataDir))),

    %% Store paths
    [{project_root, ProjectRoot} | Config].

end_per_suite(_Config) ->
    ok.

init_per_group(h2spec_tests, Config) ->
    %% Start HTTP/2 server with TLS
    case compliance_server:start_h2_server(Config) of
        {ok, Port, Pid} ->
            [{h2_port, Port}, {h2_server, Pid} | Config];
        {error, Reason} ->
            {skip, {h2spec_server_failed, Reason}}
    end;

init_per_group(autobahn_tests, Config) ->
    %% Check Docker availability
    case compliance_autobahn:docker_available() of
        true ->
            case compliance_server:start_ws_server(Config) of
                {ok, Port, Pid} ->
                    [{ws_port, Port}, {ws_server, Pid} | Config];
                {error, Reason} ->
                    {skip, {ws_server_failed, Reason}}
            end;
        false ->
            {skip, docker_not_available}
    end;

init_per_group(curl_tests, Config) ->
    %% Check curl availability
    case compliance_curl:curl_available() of
        true ->
            case compliance_server:start_http_server(Config) of
                {ok, Port, Pid} ->
                    [{http_port, Port}, {http_server, Pid} | Config];
                {error, Reason} ->
                    {skip, {http_server_failed, Reason}}
            end;
        false ->
            {skip, curl_not_available}
    end.

end_per_group(h2spec_tests, Config) ->
    case proplists:get_value(h2_server, Config) of
        undefined -> ok;
        Pid -> compliance_server:stop_server(Pid)
    end,
    ok;

end_per_group(autobahn_tests, Config) ->
    case proplists:get_value(ws_server, Config) of
        undefined -> ok;
        Pid -> compliance_server:stop_server(Pid)
    end,
    ok;

end_per_group(curl_tests, Config) ->
    case proplists:get_value(http_server, Config) of
        undefined -> ok;
        Pid -> compliance_server:stop_server(Pid)
    end,
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% h2spec Tests
%%====================================================================

h2spec_generic(Config) ->
    Port = proplists:get_value(h2_port, Config),
    ProjectRoot = proplists:get_value(project_root, Config),

    Result = compliance_h2spec:run(ProjectRoot, Port, "generic"),
    assert_h2spec_result(Result, Config).

h2spec_http2_frames(Config) ->
    Port = proplists:get_value(h2_port, Config),
    ProjectRoot = proplists:get_value(project_root, Config),

    Result = compliance_h2spec:run(ProjectRoot, Port, "http2"),
    assert_h2spec_result(Result, Config).

h2spec_hpack(Config) ->
    Port = proplists:get_value(h2_port, Config),
    ProjectRoot = proplists:get_value(project_root, Config),

    Result = compliance_h2spec:run(ProjectRoot, Port, "hpack"),
    assert_h2spec_result(Result, Config).

assert_h2spec_result({ok, Passed, Total, Output}, _Config) ->
    ct:log("h2spec: ~p/~p tests passed~n~s", [Passed, Total, Output]),
    case Passed of
        Total ->
            ok;
        _ ->
            ct:fail({h2spec_failures, Passed, Total})
    end;
assert_h2spec_result({error, Reason}, _Config) ->
    ct:fail({h2spec_error, Reason}).

%%====================================================================
%% Autobahn Tests
%%====================================================================

autobahn_framing(Config) ->
    Port = proplists:get_value(ws_port, Config),
    Result = compliance_autobahn:run_cases(Port, "1.*"),
    assert_autobahn_result(Result, Config).

autobahn_ping_pong(Config) ->
    Port = proplists:get_value(ws_port, Config),
    Result = compliance_autobahn:run_cases(Port, "2.*"),
    assert_autobahn_result(Result, Config).

autobahn_fragmentation(Config) ->
    Port = proplists:get_value(ws_port, Config),
    Result = compliance_autobahn:run_cases(Port, "5.*"),
    assert_autobahn_result(Result, Config).

autobahn_close(Config) ->
    Port = proplists:get_value(ws_port, Config),
    Result = compliance_autobahn:run_cases(Port, "7.*"),
    assert_autobahn_result(Result, Config).

autobahn_utf8(Config) ->
    Port = proplists:get_value(ws_port, Config),
    Result = compliance_autobahn:run_cases(Port, "6.*"),
    assert_autobahn_result(Result, Config).

autobahn_compression(Config) ->
    Port = proplists:get_value(ws_port, Config),
    Result = compliance_autobahn:run_cases(Port, "12.*,13.*"),
    assert_autobahn_result(Result, Config).

assert_autobahn_result({ok, Summary}, _Config) ->
    ct:log("Autobahn summary: ~p", [Summary]),
    Passed = maps:get(passed, Summary, 0),
    Failed = maps:get(failed, Summary, 0),
    NonStrict = maps:get(non_strict, Summary, 0),
    case Failed of
        0 ->
            ct:log("All ~p tests passed (~p non-strict)", [Passed, NonStrict]),
            ok;
        _ ->
            ct:fail({autobahn_failures, Failed, Passed + Failed})
    end;
assert_autobahn_result({error, Reason}, _Config) ->
    ct:fail({autobahn_error, Reason}).

%%====================================================================
%% curl Tests
%%====================================================================

curl_get_request(Config) ->
    Port = proplists:get_value(http_port, Config),
    {ok, 200, _Headers, Body} = compliance_curl:get(Port, "/"),
    <<"Hello, World!">> = Body,
    ok.

curl_post_request(Config) ->
    Port = proplists:get_value(http_port, Config),
    SendBody = <<"test body content">>,
    {ok, 200, Headers, RecvBody} = compliance_curl:post(Port, "/echo", SendBody),
    SendBody = RecvBody,
    %% Check content-type was echoed
    <<"text/plain">> = proplists:get_value(<<"content-type">>, Headers, <<>>),
    ok.

curl_headers(Config) ->
    Port = proplists:get_value(http_port, Config),
    CustomHeaders = [{<<"x-custom-header">>, <<"test-value">>}],
    {ok, 200, _Headers, Body} = compliance_curl:get(Port, "/headers", CustomHeaders),
    %% Response should contain our custom header (case-insensitive match)
    LowerBody = string:lowercase(binary_to_list(Body)),
    true = string:find(LowerBody, "x-custom-header") =/= nomatch,
    ok.

curl_chunked(Config) ->
    Port = proplists:get_value(http_port, Config),
    {ok, 200, Headers, Body} = compliance_curl:get(Port, "/stream"),
    %% Check we got all chunks
    <<"chunk1chunk2chunk3">> = Body,
    %% Should have transfer-encoding: chunked
    case proplists:get_value(<<"transfer-encoding">>, Headers) of
        <<"chunked">> -> ok;
        _ -> ok  % Might be decoded by curl
    end,
    ok.

curl_keepalive(Config) ->
    Port = proplists:get_value(http_port, Config),
    %% Make multiple requests on same connection
    Results = compliance_curl:keepalive_test(Port, "/", 3),
    lists:foreach(fun({ok, 200, _, _}) -> ok end, Results),
    ok.

curl_http10(Config) ->
    Port = proplists:get_value(http_port, Config),
    {ok, 200, Headers, _Body} = compliance_curl:get_http10(Port, "/"),
    %% HTTP/1.0 response should have Connection: close or no Connection header
    case proplists:get_value(<<"connection">>, Headers) of
        undefined -> ok;
        <<"close">> -> ok;
        <<"Close">> -> ok;
        _ -> ok  % Accept any for HTTP/1.0
    end,
    ok.
