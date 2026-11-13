%% @doc CT suite for the H2 adapter.
%%
%% Starts a `livery_h2' listener (h2c, no TLS), drives real requests
%% through the `h2' library's own client API, and asserts on status,
%% headers, body, and streaming behaviour.
-module(livery_h2_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% 8 MiB: far more than either stream window.
-define(SLOW_BODY, 8388608).
-define(REQUEST_TIMEOUT, 5000).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    text_response/1,
    emit_reset_no_disconnect/1,
    json_response/1,
    empty_response/1,
    streaming_chunked_response/1,
    sse_response/1,
    echo_buffered_body/1,
    authority_request/1,
    error_500_on_crash/1,
    response_with_trailers/1,
    cancel_on_connection_close/1,
    cancelled_requests_leave_no_worker/1,
    slow_reader_holds_client_back/1,
    send_to_gone_client_is_closed/1,
    peer_on_request/1,
    early_hints_interim/1,
    oversize_upload_delivers_413/1,
    oversize_open_upload_delivers_413/1
]).

%%====================================================================
%% Suite plumbing
%%====================================================================

all() ->
    [
        text_response,
        emit_reset_no_disconnect,
        json_response,
        empty_response,
        streaming_chunked_response,
        sse_response,
        echo_buffered_body,
        authority_request,
        error_500_on_crash,
        response_with_trailers,
        cancel_on_connection_close,
        cancelled_requests_leave_no_worker,
        slow_reader_holds_client_back,
        send_to_gone_client_is_closed,
        peer_on_request,
        early_hints_interim,
        oversize_upload_delivers_413,
        oversize_open_upload_delivers_413
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
    {ok, Listener} = livery_h2:start(
        maps:merge(opts_for(TC), #{
            port => 0,
            transport => tcp,
            stack => stack_for(TC),
            handler => handler_for(TC)
        })
    ),
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

%% A body over `max_body' gets the handler's 413, not a stream reset.
oversize_upload_delivers_413(Config) ->
    {Status, _, Body, _} = post(Config, <<"/">>, binary:copy(<<"x">>, 64)),
    ?assertEqual(413, Status),
    ?assertEqual(<<"{\"error\":\"too_big\"}">>, Body).

%% The client is still sending when the 413 goes out: it reads the
%% response, then RST_STREAM(NO_ERROR) tells it to stop.
oversize_open_upload_delivers_413(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, StreamId} = h2:request(
        Conn,
        [
            {<<":method">>, <<"POST">>},
            {<<":path">>, <<"/">>},
            {<<":scheme">>, <<"http">>},
            {<<":authority">>, <<"127.0.0.1">>}
        ],
        #{end_stream => false}
    ),
    ok = h2:send_data(Conn, StreamId, binary:copy(<<"x">>, 64), false),
    {Status, _, Body, _} = collect_response(Conn, StreamId, undefined, [], [], undefined),
    ?assertEqual(413, Status),
    ?assertEqual(<<"{\"error\":\"too_big\"}">>, Body),
    receive
        {h2, Conn, {stream_reset, StreamId, Reason}} -> ?assertEqual(no_error, Reason)
    after 5000 -> ct:fail(no_stream_reset)
    end,
    h2:close(Conn).

%%====================================================================
%% Handlers
%%====================================================================

opts_for(oversize_upload_delivers_413) -> #{max_body => 8};
opts_for(oversize_open_upload_delivers_413) -> #{max_body => 8};
opts_for(_TC) -> #{}.

stack_for(_TC) -> [].

handler_for(TC) when
    TC =:= oversize_upload_delivers_413; TC =:= oversize_open_upload_delivers_413
->
    fun(R) ->
        {stream, Reader} = livery_req:body(R),
        case livery_body:read_all(Reader, 5000) of
            {ok, Bytes, _} -> livery_resp:text(200, Bytes);
            {error, body_too_large, _} -> livery_resp:json(413, <<"{\"error\":\"too_big\"}">>)
        end
    end;
handler_for(peer_on_request) ->
    fun(R) ->
        Body =
            case livery_req:peer(R) of
                {{127, 0, 0, 1}, Port} when is_integer(Port), Port > 0 ->
                    <<"peer-ok">>;
                Other ->
                    iolist_to_binary(io_lib:format("~p", [Other]))
            end,
        livery_resp:text(200, Body)
    end;
handler_for(slow_reader_holds_client_back) ->
    fun(R) ->
        %% Count what reached this mailbox twice, without reading. Held
        %% back by flow control, the client is stuck at its limit, so the
        %% count stops growing, below the whole body.
        timer:sleep(600),
        Early = queued_body_bytes(),
        timer:sleep(600),
        Late = queued_body_bytes(),
        {stream, Reader} = livery_req:body(R),
        {ok, Bytes, _} = livery_body:read_all(Reader, 20000),
        livery_resp:text(200, [
            integer_to_binary(Early),
            <<" ">>,
            integer_to_binary(Late),
            <<" ">>,
            integer_to_binary(byte_size(Bytes))
        ])
    end;
handler_for(cancelled_requests_leave_no_worker) ->
    fun(R) ->
        {stream, Reader} = livery_req:body(R),
        _ = livery_body:read_all(Reader, 5000),
        livery_resp:text(200, <<"read">>)
    end;
handler_for(early_hints_interim) ->
    fun(R) ->
        ok = livery_req:inform(
            103, [{<<"link">>, <<"</app.css>; rel=preload; as=style">>}], R
        ),
        livery_resp:text(200, <<"hinted">>)
    end;
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
handler_for(emit_reset_no_disconnect) ->
    %% A directory is not a regular file, so emit resets the stream.
    Test = self(),
    Dir = filename:dirname(code:which(?MODULE)),
    fun(R) ->
        ok = livery_req:on_disconnect(R, fun() -> Test ! cancelled end),
        Test ! handler_ready,
        livery_resp:file(200, Dir)
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

%% A reset livery issues itself (here emit failing on a file response)
%% is not a client disconnect: on_disconnect callbacks must not run.
emit_reset_no_disconnect(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, _StreamId} = h2:request(Conn, <<"GET">>, <<"/">>, [{<<"host">>, <<"127.0.0.1">>}]),
    receive
        handler_ready -> ok
    after 5000 -> ct:fail(handler_did_not_start)
    end,
    receive
        cancelled -> ct:fail(on_disconnect_fired_on_local_reset)
    after 1000 -> ok
    end,
    h2:close(Conn).

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

%% A handler that does not read yet holds the client back to the stream
%% window, then still gets the whole body once it reads.
slow_reader_holds_client_back(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, StreamId} = h2:request(Conn, post_headers(), #{end_stream => false}),
    Piece = binary:copy(<<"x">>, 65536),
    Pieces = ?SLOW_BODY div 65536,
    _ = spawn_link(fun() ->
        [
            ok = h2:send_data(Conn, StreamId, Piece, N =:= Pieces, #{block => 30000})
         || N <- lists:seq(1, Pieces)
        ]
    end),
    {Status, _, Body, _} = collect_response(Conn, StreamId, undefined, [], [], undefined),
    ?assertEqual(200, Status),
    [Early, Late, Read] = [binary_to_integer(B) || B <- binary:split(Body, <<" ">>, [global])],
    ?assertEqual(?SLOW_BODY, Read),
    %% Held back, the client sends nothing more while the handler does not
    %% read, and never the whole body. Without flow control the count is
    %% still growing, or the whole body is already in.
    ?assertEqual(Early, Late),
    ?assert(Late < ?SLOW_BODY),
    h2:close(Conn).

post_headers() ->
    [
        {<<":method">>, <<"POST">>},
        {<<":path">>, <<"/">>},
        {<<":scheme">>, <<"http">>},
        {<<":authority">>, <<"127.0.0.1">>}
    ].

%% Streams the client cancels right after their HEADERS must not leave
%% a request worker behind, whether the cancel lands before or after
%% the stream is registered.
cancelled_requests_leave_no_worker(Config) ->
    Before = livery_req_sup:in_flight(),
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    Headers = [
        {<<":method">>, <<"POST">>},
        {<<":path">>, <<"/">>},
        {<<":scheme">>, <<"http">>},
        {<<":authority">>, <<"127.0.0.1">>}
    ],
    [
        begin
            {ok, StreamId} = h2:request(Conn, Headers, #{end_stream => false}),
            _ = h2:cancel(Conn, StreamId)
        end
     || _ <- lists:seq(1, 50)
    ],
    await_in_flight(Before, 2000),
    h2:close(Conn).

%% Wait until no request worker is left, or fail after Ms.
await_in_flight(Expected, Ms) when Ms =< 0 ->
    ?assertEqual(Expected, livery_req_sup:in_flight());
await_in_flight(Expected, Ms) ->
    case livery_req_sup:in_flight() of
        Expected ->
            ok;
        _ ->
            timer:sleep(20),
            await_in_flight(Expected, Ms - 20)
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
    Stream = {Dead, 1, <<"h2">>},
    ?assertEqual({error, closed}, livery_h2:send_full(Stream, 200, [], <<"body">>, #{})),
    ?assertEqual(
        {error, closed}, livery_h2:send_data(Stream, <<"body">>, #{end_stream => true})
    ),
    ?assertEqual(
        {error, closed}, livery_h2:send_headers(Stream, 200, [], #{end_stream => true})
    ),
    ?assertEqual({error, closed}, livery_h2:send_trailers(Stream, [{<<"x">>, <<"y">>}])).

%% Regression: livery_req:peer/1 carries the client address on plain
%% HTTP/2 requests (it used to be undefined).
peer_on_request(Config) ->
    {Status, _Headers, Body, _} = get(Config, <<"/">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"peer-ok">>, Body).

%% A 103 interim HEADERS block reaches the client ahead of the final
%% response on the same stream.
early_hints_interim(Config) ->
    Port = ?config(port, Config),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, StreamId} = h2:request(Conn, <<"GET">>, <<"/">>, [
        {<<"host">>, <<"127.0.0.1">>}
    ]),
    {Infos, {Status, _Headers, Body, _}} = collect_with_informational(Conn, StreamId),
    ?assertMatch([{103, _}], Infos),
    [{103, Hs}] = Infos,
    ?assertEqual(
        <<"</app.css>; rel=preload; as=style">>,
        header(<<"link">>, Hs)
    ),
    ?assertEqual(200, Status),
    ?assertEqual(<<"hinted">>, Body),
    h2:close(Conn).

collect_with_informational(Conn, StreamId) ->
    collect_with_informational(Conn, StreamId, []).

%% Interim events strictly precede the final response HEADERS; once
%% that arrives, hand off to the shared collector for body/trailers.
collect_with_informational(Conn, StreamId, Infos) ->
    receive
        {h2, Conn, {informational, StreamId, S, Hs}} ->
            collect_with_informational(Conn, StreamId, [{S, Hs} | Infos]);
        {h2, Conn, {response, StreamId, S, Hs}} ->
            Result = collect_response(Conn, StreamId, S, Hs, [], undefined),
            {lists:reverse(Infos), Result}
    after ?REQUEST_TIMEOUT ->
        {lists:reverse(Infos), {error, timeout}}
    end.

%%====================================================================
%% HTTP/2 client helpers
%%====================================================================

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

%% Body bytes already in this mailbox, not yet read.
queued_body_bytes() ->
    {messages, Msgs} = process_info(self(), messages),
    lists:sum([iolist_size(D) || {livery_body, _, {data, D}} <- Msgs]).
