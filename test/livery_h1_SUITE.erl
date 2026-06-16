%% @doc CT suite for the H1 adapter.
%%
%% Starts a `livery_h1' listener on an ephemeral port, drives real
%% TCP requests through hackney, and asserts on status, headers,
%% body, and streaming behaviour.
-module(livery_h1_SUITE).

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
    binding_via_routed_handler/1,
    read_query_string/1,
    streaming_chunked_response/1,
    sse_response/1,
    echo_buffered_body/1,
    body_ceiling_rejects_oversize/1,
    oversize_upload_delivers_413/1,
    early_response_no_read_delivers_413/1,
    error_500_on_crash/1,
    cancel_on_client_disconnect/1
]).

%%====================================================================
%% Suite plumbing
%%====================================================================

all() ->
    [
        text_response,
        json_response,
        empty_response,
        binding_via_routed_handler,
        read_query_string,
        streaming_chunked_response,
        sse_response,
        echo_buffered_body,
        body_ceiling_rejects_oversize,
        oversize_upload_delivers_413,
        early_response_no_read_delivers_413,
        error_500_on_crash,
        cancel_on_client_disconnect
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(h1),
    {ok, _} = application:ensure_all_started(hackney),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(hackney),
    _ = application:stop(h1),
    _ = application:stop(livery),
    ok.

init_per_testcase(TC, Config) ->
    Stack = stack_for(TC),
    Handler = handler_for(TC),
    {ok, Listener} = livery_h1:start(#{
        port => 0,
        stack => Stack,
        handler => Handler,
        max_body => max_body_for(TC)
    }),
    Port = h1:server_port(Listener),
    [{listener, Listener}, {port, Port} | Config].

end_per_testcase(_TC, Config) ->
    Listener = ?config(listener, Config),
    livery_h1:stop(Listener),
    ok.

%%====================================================================
%% Cases
%%====================================================================

text_response(Config) ->
    {ok, Status, Headers, Body} = get(Config, <<"/">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"hello">>, Body),
    ?assertEqual(
        <<"text/plain; charset=utf-8">>,
        header(<<"content-type">>, Headers)
    ).

json_response(Config) ->
    {ok, Status, Headers, Body} = get(Config, <<"/">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"{\"ok\":true}">>, Body),
    ?assertEqual(
        <<"application/json">>,
        header(<<"content-type">>, Headers)
    ).

empty_response(Config) ->
    {ok, Status, _Headers, Body} = get(Config, <<"/">>),
    ?assertEqual(204, Status),
    ?assertEqual(<<>>, Body).

binding_via_routed_handler(Config) ->
    %% No router yet; emulate by reading the path inside the handler.
    {ok, 200, _, Body} = get(Config, <<"/hi/alice">>),
    ?assertEqual(<<"hello, alice">>, Body).

%% The query string survives the H1 transport: livery_ext:query/2 reads
%% the values (URL-decoded) the handler asked for.
read_query_string(Config) ->
    {ok, 200, _, Body} = get(Config, <<"/search?q=hello%20world&page=2">>),
    ?assertEqual(<<"hello world|2">>, Body).

streaming_chunked_response(Config) ->
    {ok, 200, _, Body} = get(Config, <<"/">>),
    ?assertEqual(<<"12345">>, Body).

sse_response(Config) ->
    {ok, 200, Headers, Body} = get(Config, <<"/">>),
    ?assertEqual(
        <<"text/event-stream">>,
        header(<<"content-type">>, Headers)
    ),
    ?assertEqual(
        <<"event: tick\ndata: 1\n\nevent: tick\ndata: 2\n\n">>,
        Body
    ).

echo_buffered_body(Config) ->
    {ok, 200, _, Body} = post(Config, <<"/">>, <<"echo me">>),
    ?assertEqual(<<"echo me">>, Body).

body_ceiling_rejects_oversize(Config) ->
    %% max_body is 64 for this case (see max_body_for/1).
    {ok, 200, _, _} = post(Config, <<"/">>, binary:copy(<<"x">>, 32)),
    {ok, Over, _, _} = post(Config, <<"/">>, binary:copy(<<"x">>, 256)),
    ?assertEqual(413, Over).

%% A large upload past the listener's `max_body' cap must still deliver the
%% handler's 413: the cap aborts the body read, the handler responds, and
%% h1's early-response drain reads the rest before closing so the client
%% reads the response instead of a reset. Looped to shake the race.
oversize_upload_delivers_413(Config) ->
    %% max_body is 1 MiB for this case; the body is 2 MiB.
    Body = binary:copy(<<"x">>, 2 * 1024 * 1024),
    lists:foreach(
        fun(_) ->
            {ok, Status, _, RBody} = post_no_pool(Config, <<"/">>, Body),
            ?assertEqual(413, Status),
            ?assertEqual(<<"{\"error\":\"too_big\"}">>, RBody)
        end,
        lists:seq(1, 25)
    ).

%% A handler that commits a 413 without reading the (large, in-flight) body
%% must still deliver it. h1 drains the leftover inbound body before closing.
early_response_no_read_delivers_413(Config) ->
    Body = binary:copy(<<"x">>, 2 * 1024 * 1024),
    lists:foreach(
        fun(_) ->
            ?assertMatch({ok, 413, _, _}, post_no_pool(Config, <<"/">>, Body))
        end,
        lists:seq(1, 25)
    ).

error_500_on_crash(Config) ->
    {ok, Status, _Headers, Body} = get(Config, <<"/">>),
    ?assertEqual(500, Status),
    ?assertEqual(<<"internal server error">>, Body).

cancel_on_client_disconnect(Config) ->
    %% Raw socket so we control the close. The handler registers an
    %% on_disconnect callback and then reads the request body; HTTP/1.1
    %% is half-duplex, so the disconnect is detected while the server
    %% is reading the (incomplete) body. The client promises a large
    %% body, sends a few bytes, then closes.
    Port = ?config(port, Config),
    {ok, Sock} = gen_tcp:connect(
        "127.0.0.1", Port, [binary, {active, false}], 5000
    ),
    ok = gen_tcp:send(Sock, <<
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\nhi"
    >>),
    receive
        handler_ready -> ok
    after 5000 -> ct:fail(handler_did_not_start)
    end,
    ok = gen_tcp:close(Sock),
    receive
        cancelled -> ok
    after 5000 -> ct:fail(cancel_callback_not_run)
    end.

%%====================================================================
%% Handlers
%%====================================================================

stack_for(_TC) -> [].

%% Small ceiling for the over-size case; default for everything else.
max_body_for(body_ceiling_rejects_oversize) -> 64;
max_body_for(oversize_upload_delivers_413) -> 1024 * 1024;
max_body_for(_TC) -> 16 * 1024 * 1024.

handler_for(text_response) ->
    fun(_R) -> livery_resp:text(200, <<"hello">>) end;
handler_for(json_response) ->
    fun(_R) -> livery_resp:json(200, <<"{\"ok\":true}">>) end;
handler_for(empty_response) ->
    fun(_R) -> livery_resp:empty(204) end;
handler_for(binding_via_routed_handler) ->
    fun(R) ->
        case livery_req:path(R) of
            <<"/hi/", Name/binary>> ->
                livery_resp:text(200, [<<"hello, ">>, Name]);
            _ ->
                livery_resp:text(404, <<>>)
        end
    end;
handler_for(read_query_string) ->
    fun(R) ->
        Q = livery_ext:query(<<"q">>, R),
        Page = livery_ext:query(<<"page">>, R),
        livery_resp:text(200, [Q, <<"|">>, Page])
    end;
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
handler_for(body_ceiling_rejects_oversize) ->
    fun(R) ->
        {stream, Reader} = livery_req:body(R),
        case livery_body:read_all(Reader, 5000) of
            {ok, Bytes, _} -> livery_resp:text(200, Bytes);
            {error, body_too_large, _} -> livery_resp:text(413, <<"too large">>)
        end
    end;
handler_for(oversize_upload_delivers_413) ->
    fun(R) ->
        {stream, Reader} = livery_req:body(R),
        case livery_body:read_all(Reader, 5000) of
            {ok, Bytes, _} -> livery_resp:text(200, Bytes);
            {error, body_too_large, _} -> livery_resp:json(413, <<"{\"error\":\"too_big\"}">>)
        end
    end;
handler_for(early_response_no_read_delivers_413) ->
    %% Commit a 413 without reading the body at all.
    fun(_R) -> livery_resp:json(413, <<"{\"error\":\"too_big\"}">>) end;
handler_for(error_500_on_crash) ->
    fun(_R) -> error(boom) end;
handler_for(cancel_on_client_disconnect) ->
    Test = self(),
    fun(R) ->
        ok = livery_req:on_disconnect(R, fun() -> Test ! cancelled end),
        Test ! handler_ready,
        {stream, Reader} = livery_req:body(R),
        _ = livery_body:read_all(Reader, 10000),
        livery_resp:text(200, <<"done">>)
    end.

%%====================================================================
%% HTTP helpers (hackney)
%%====================================================================

-define(REQUEST_TIMEOUT, 5000).

get(Config, Path) ->
    request(<<"GET">>, Config, Path, <<>>).

post(Config, Path, Body) ->
    request(<<"POST">>, Config, Path, Body).

request(Method, Config, Path, Body) ->
    Port = ?config(port, Config),
    Url = iolist_to_binary([<<"http://127.0.0.1:">>, integer_to_binary(Port), Path]),
    Headers =
        case byte_size(Body) of
            0 -> [];
            _ -> [{<<"Content-Length">>, integer_to_binary(byte_size(Body))}]
        end,
    {ok, Status, RespHeaders, RespBody} =
        hackney:request(
            Method,
            Url,
            Headers,
            Body,
            [with_body, {recv_timeout, ?REQUEST_TIMEOUT}]
        ),
    {ok, Status, normalize(RespHeaders), RespBody}.

%% POST without hackney's connection pool so each request rides a fresh
%% socket. Used by the early-response cases, where the server closes the
%% connection after delivering the response. Returns hackney's error tuple
%% verbatim so a lost response (the bug) fails the assertion clearly.
post_no_pool(Config, Path, Body) ->
    Port = ?config(port, Config),
    Url = iolist_to_binary([<<"http://127.0.0.1:">>, integer_to_binary(Port), Path]),
    Headers = [{<<"Content-Length">>, integer_to_binary(byte_size(Body))}],
    case
        hackney:request(
            <<"POST">>,
            Url,
            Headers,
            Body,
            [with_body, {pool, false}, {recv_timeout, ?REQUEST_TIMEOUT}]
        )
    of
        {ok, Status, RespHeaders, RespBody} ->
            {ok, Status, normalize(RespHeaders), RespBody};
        {error, _} = Error ->
            Error
    end.

normalize(Headers) ->
    [{string:lowercase(N), V} || {N, V} <- Headers].

header(Name, Headers) ->
    LName = string:lowercase(Name),
    case lists:keyfind(LName, 1, Headers) of
        {_, V} when is_binary(V) -> V;
        {_, V} when is_list(V) -> list_to_binary(V);
        false -> undefined
    end.
