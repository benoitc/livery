%% @doc CT suite for the H2 adapter.
%%
%% Starts a `livery_h2' listener (h2c, no TLS), drives real requests
%% through the `h2' library's own client API, and asserts on status,
%% headers, body, and streaming behaviour.
-module(livery_h2_SUITE).

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
    text_response/1,
    json_response/1,
    empty_response/1,
    streaming_chunked_response/1,
    sse_response/1,
    echo_buffered_body/1,
    authority_request/1,
    error_500_on_crash/1,
    response_with_trailers/1,
    cancel_on_connection_close/1,
    send_to_gone_client_is_closed/1
]).

%%====================================================================
%% Suite plumbing
%%====================================================================

all() ->
    [
        text_response,
        json_response,
        empty_response,
        streaming_chunked_response,
        sse_response,
        echo_buffered_body,
        authority_request,
        error_500_on_crash,
        response_with_trailers,
        cancel_on_connection_close,
        send_to_gone_client_is_closed
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(h2),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(h2),
    _ = application:stop(livery),
    ok.

init_per_testcase(TC, Config) ->
    {ok, Listener} = livery_h2:start(#{
        port => 0,
        transport => tcp,
        stack => stack_for(TC),
        handler => handler_for(TC)
    }),
    Port = h2:server_port(Listener),
    [{listener, Listener}, {port, Port} | Config].

end_per_testcase(_TC, Config) ->
    Listener = ?config(listener, Config),
    livery_h2:stop(Listener),
    ok.

%%====================================================================
%% Cases
%%====================================================================

text_response(Config) ->
    {Status, Headers, Body, _} = get(Config, <<"/">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"hello">>, Body),
    ?assertEqual(
        <<"text/plain; charset=utf-8">>,
        header(<<"content-type">>, Headers)
    ).

json_response(Config) ->
    {Status, Headers, Body, _} = get(Config, <<"/">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"{\"ok\":true}">>, Body),
    ?assertEqual(
        <<"application/json">>,
        header(<<"content-type">>, Headers)
    ).

empty_response(Config) ->
    {Status, _Headers, Body, _} = get(Config, <<"/">>),
    ?assertEqual(204, Status),
    ?assertEqual(<<>>, Body).

streaming_chunked_response(Config) ->
    {200, _, Body, _} = get(Config, <<"/">>),
    ?assertEqual(<<"12345">>, Body).

sse_response(Config) ->
    {200, Headers, Body, _} = get(Config, <<"/">>),
    ?assertEqual(
        <<"text/event-stream">>,
        header(<<"content-type">>, Headers)
    ),
    ?assertEqual(<<"event: tick\ndata: 1\n\nevent: tick\ndata: 2\n\n">>, Body).

echo_buffered_body(Config) ->
    {200, _, Body, _} = post(Config, <<"/">>, <<"echo me">>),
    ?assertEqual(<<"echo me">>, Body).

%% h2 0.10.2 keeps `:authority'/`:scheme' in the handler header list. The
%% adapter exposes them via livery_req:authority/1 and scheme/1, synthesizes
%% a `host' header from the authority when the client omits one, and strips
%% the pseudo-headers from the application-visible headers.
authority_request(Config) ->
    {200, _, Body, _} = get_authority(Config, <<"example.localhost">>),
    ?assertEqual(<<"example.localhost|example.localhost|http|none|none">>, Body).

error_500_on_crash(Config) ->
    {Status, _, Body, _} = get(Config, <<"/">>),
    ?assertEqual(500, Status),
    ?assertEqual(<<"internal server error">>, Body).

response_with_trailers(Config) ->
    {200, _, Body, Trailers} = get(Config, <<"/">>),
    ?assertEqual(<<"hello">>, Body),
    ?assertEqual([{<<"x-checksum">>, <<"abc">>}], Trailers).

%%====================================================================
%% Handlers
%%====================================================================

stack_for(_TC) -> [].

handler_for(text_response) ->
    fun(_R) -> livery_resp:text(200, <<"hello">>) end;
handler_for(json_response) ->
    fun(_R) -> livery_resp:json(200, <<"{\"ok\":true}">>) end;
handler_for(empty_response) ->
    fun(_R) -> livery_resp:empty(204) end;
handler_for(streaming_chunked_response) ->
    Producer = fun(Emit) ->
        [Emit(integer_to_binary(N)) || N <- lists:seq(1, 5)],
        ok
    end,
    fun(_R) -> livery_resp:stream(200, [], Producer) end;
handler_for(sse_response) ->
    Producer = fun(Emit) ->
        Emit(#{event => <<"tick">>, data => <<"1">>}),
        Emit(#{event => <<"tick">>, data => <<"2">>}),
        ok
    end,
    fun(_R) -> livery_resp:sse(200, Producer) end;
handler_for(echo_buffered_body) ->
    fun(R) ->
        {stream, Reader} = livery_req:body(R),
        {ok, Bytes, _} = livery_body:read_all(Reader, 5000),
        livery_resp:text(200, Bytes)
    end;
handler_for(authority_request) ->
    fun(R) ->
        Fields = [
            livery_req:authority(R),
            livery_req:header(<<"host">>, R, <<"none">>),
            livery_req:scheme(R),
            livery_req:header(<<":authority">>, R, <<"none">>),
            livery_req:header(<<":scheme">>, R, <<"none">>)
        ],
        livery_resp:text(200, lists:join(<<"|">>, Fields))
    end;
handler_for(error_500_on_crash) ->
    fun(_R) -> error(boom) end;
handler_for(response_with_trailers) ->
    fun(_R) ->
        Resp = livery_resp:text(200, <<"hello">>),
        livery_resp:with_trailers([{<<"x-checksum">>, <<"abc">>}], Resp)
    end;
handler_for(cancel_on_connection_close) ->
    Test = self(),
    fun(R) ->
        ok = livery_req:on_disconnect(R, fun() -> Test ! cancelled end),
        livery_resp:stream(200, [], fun(Emit) ->
            Emit(<<"start">>),
            Test ! handler_ready,
            receive
                {livery_disconnect, _, _} -> ok
            after 10000 -> ok
            end
        end)
    end;
%% Cases that exercise the adapter directly (no listener traffic).
handler_for(_TC) ->
    fun(_R) -> livery_resp:text(200, <<"ok">>) end.

cancel_on_connection_close(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, _StreamId} = h2:request(Conn, <<"GET">>, <<"/">>, [
        {<<"host">>, <<"127.0.0.1">>}
    ]),
    receive
        handler_ready -> ok
    after 5000 -> ct:fail(handler_did_not_start)
    end,
    %% Closing the client connection terminates the server-side h2
    %% connection process, which the translator monitors -> fire.
    h2:close(Conn),
    receive
        cancelled -> ok
    after 5000 -> ct:fail(cancel_callback_not_run)
    end.

%% A send to a connection whose client has gone away must report
%% `{error, closed}` (like gen_tcp:send on H1), not crash the worker.
%% The crash path would error-log the response body carried in the
%% stacktrace, a throughput sink on large responses. A dead connection
%% process makes the underlying gen_statem:call exit with `{noproc, _}`,
%% the same shape as a real mid-response disconnect.
send_to_gone_client_is_closed(_Config) ->
    Dead = spawn(fun() -> ok end),
    Ref = monitor(process, Dead),
    receive
        {'DOWN', Ref, process, Dead, _} -> ok
    after 5000 -> ct:fail(proc_not_dead)
    end,
    Stream = {Dead, 1},
    ?assertEqual({error, closed}, livery_h2:send_full(Stream, 200, [], <<"body">>, #{})),
    ?assertEqual(
        {error, closed}, livery_h2:send_data(Stream, <<"body">>, #{end_stream => true})
    ),
    ?assertEqual(
        {error, closed}, livery_h2:send_headers(Stream, 200, [], #{end_stream => true})
    ),
    ?assertEqual({error, closed}, livery_h2:send_trailers(Stream, [{<<"x">>, <<"y">>}])).

%%====================================================================
%% HTTP/2 client helpers
%%====================================================================

-define(REQUEST_TIMEOUT, 5000).

get(Config, Path) ->
    request(<<"GET">>, Config, Path, <<>>).

%% Send an explicit `:authority' and no `host' header, so the test can
%% assert the adapter populates the authority and synthesizes `host'.
get_authority(Config, Authority) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, StreamId} = h2:request(Conn, [
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>},
        {<<":scheme">>, <<"http">>},
        {<<":authority">>, Authority}
    ]),
    Result = collect_response(Conn, StreamId, undefined, [], [], undefined),
    h2:close(Conn),
    Result.

post(Config, Path, Body) ->
    request(<<"POST">>, Config, Path, Body).

request(Method, Config, Path, Body) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    Headers = base_headers(Method, Path),
    {ok, StreamId} =
        case byte_size(Body) of
            0 ->
                h2:request(Conn, Method, Path, Headers);
            _ ->
                h2:request(
                    Conn,
                    Method,
                    Path,
                    Headers ++ [{<<"content-length">>, integer_to_binary(byte_size(Body))}],
                    Body
                )
        end,
    Result = collect_response(Conn, StreamId, undefined, [], [], undefined),
    h2:close(Conn),
    Result.

base_headers(_Method, _Path) ->
    %% Pseudo-headers are injected by h2:send_request. Use a regular
    %% `host' header for :authority derivation.
    [{<<"host">>, <<"127.0.0.1">>}].

collect_response(Conn, StreamId, Status, Headers, BodyAcc, Trailers) ->
    receive
        {h2, Conn, {response, StreamId, S, Hs}} ->
            collect_response(Conn, StreamId, S, Hs, BodyAcc, Trailers);
        {h2, Conn, {data, StreamId, Chunk, false}} ->
            collect_response(
                Conn,
                StreamId,
                Status,
                Headers,
                [Chunk | BodyAcc],
                Trailers
            );
        {h2, Conn, {data, StreamId, Chunk, true}} ->
            {Status, Headers, iolist_to_binary(lists:reverse([Chunk | BodyAcc])), Trailers};
        {h2, Conn, {trailers, StreamId, T}} ->
            {Status, Headers, iolist_to_binary(lists:reverse(BodyAcc)), T};
        {h2, Conn, {stream_reset, StreamId, R}} ->
            {error, R};
        {h2, Conn, _Other} ->
            collect_response(Conn, StreamId, Status, Headers, BodyAcc, Trailers)
    after ?REQUEST_TIMEOUT ->
        {error, timeout}
    end.

header(Name, Headers) ->
    LName = string:lowercase(Name),
    case lists:keyfind(LName, 1, normalize(Headers)) of
        {_, V} -> V;
        false -> undefined
    end.

normalize(Hs) ->
    [{string:lowercase(N), V} || {N, V} <- Hs].
