%% @doc CT suite for the H3 adapter.
%%
%% Starts a `livery_h3' listener with self-signed certs and drives
%% real QUIC requests through the `quic' library's own H3 client.
-module(livery_h3_SUITE).

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
    error_500_on_crash/1,
    response_with_trailers/1
]).

%%====================================================================
%% Suite plumbing
%%====================================================================

all() ->
    [text_response,
     json_response,
     empty_response,
     streaming_chunked_response,
     sse_response,
     echo_buffered_body,
     error_500_on_crash,
     response_with_trailers].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(quic),
    {ok, CertDer, KeyDer} = livery_test_certs:load(),
    [{cert, CertDer}, {key, KeyDer} | Config].

end_per_suite(_Config) ->
    _ = application:stop(quic),
    _ = application:stop(livery),
    ok.

init_per_testcase(TC, Config) ->
    Cert = ?config(cert, Config),
    Key  = ?config(key, Config),
    {ok, Listener} = livery_h3:start(#{
        port      => 0,
        cert      => Cert,
        key       => Key,
        stack     => stack_for(TC),
        handler   => handler_for(TC)
    }),
    {ok, Port} = quic:get_server_port(Listener),
    [{listener, Listener}, {port, Port} | Config].

end_per_testcase(_TC, Config) ->
    Listener = ?config(listener, Config),
    livery_h3:stop(Listener),
    ok.

%%====================================================================
%% Cases
%%====================================================================

text_response(Config) ->
    {Status, Headers, Body, _} = get(Config, <<"/">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"hello">>, Body),
    ?assertEqual(<<"text/plain; charset=utf-8">>,
                 header(<<"content-type">>, Headers)).

json_response(Config) ->
    {Status, Headers, Body, _} = get(Config, <<"/">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"{\"ok\":true}">>, Body),
    ?assertEqual(<<"application/json">>,
                 header(<<"content-type">>, Headers)).

empty_response(Config) ->
    {Status, _Headers, Body, _} = get(Config, <<"/">>),
    ?assertEqual(204, Status),
    ?assertEqual(<<>>, Body).

streaming_chunked_response(Config) ->
    {200, _, Body, _} = get(Config, <<"/">>),
    ?assertEqual(<<"12345">>, Body).

sse_response(Config) ->
    {200, Headers, Body, _} = get(Config, <<"/">>),
    ?assertEqual(<<"text/event-stream">>,
                 header(<<"content-type">>, Headers)),
    ?assertEqual(<<"event: tick\ndata: 1\n\nevent: tick\ndata: 2\n\n">>, Body).

echo_buffered_body(Config) ->
    {200, _, Body, _} = post(Config, <<"/">>, <<"echo me">>),
    ?assertEqual(<<"echo me">>, Body).

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
handler_for(error_500_on_crash) ->
    fun(_R) -> error(boom) end;
handler_for(response_with_trailers) ->
    fun(_R) ->
        Resp = livery_resp:text(200, <<"hello">>),
        livery_resp:with_trailers([{<<"x-checksum">>, <<"abc">>}], Resp)
    end.

%%====================================================================
%% HTTP/3 client helpers
%%====================================================================

-define(REQUEST_TIMEOUT, 10000).

get(Config, Path) ->
    request(<<"GET">>, Config, Path, <<>>).

post(Config, Path, Body) ->
    request(<<"POST">>, Config, Path, Body).

request(Method, Config, Path, Body) ->
    Port = ?config(port, Config),
    {ok, Conn} = quic_h3:connect(<<"localhost">>, Port,
                                  #{verify => verify_none, sync => true}),
    try
        Headers = [
            {<<":method">>, Method},
            {<<":path">>, Path},
            {<<":scheme">>, <<"https">>},
            {<<":authority">>, <<"localhost">>}
        ],
        case byte_size(Body) of
            0 ->
                {ok, StreamId} = quic_h3:request(Conn, Headers,
                                                 #{end_stream => true}),
                collect_response(Conn, StreamId, undefined, [], [], undefined);
            _ ->
                Hs = Headers ++ [{<<"content-length">>,
                                   integer_to_binary(byte_size(Body))}],
                {ok, StreamId} = quic_h3:request(Conn, Hs,
                                                 #{end_stream => false}),
                ok = quic_h3:send_data(Conn, StreamId, Body, true),
                collect_response(Conn, StreamId, undefined, [], [], undefined)
        end
    after
        catch quic_h3:close(Conn)
    end.

collect_response(Conn, StreamId, Status, Headers, BodyAcc, Trailers) ->
    receive
        {quic_h3, Conn, {response, StreamId, S, Hs}} ->
            collect_response(Conn, StreamId, S, Hs, BodyAcc, Trailers);
        {quic_h3, Conn, {data, StreamId, Chunk, false}} ->
            collect_response(Conn, StreamId, Status, Headers,
                             [Chunk | BodyAcc], Trailers);
        {quic_h3, Conn, {data, StreamId, Chunk, true}} ->
            {Status, Headers,
             iolist_to_binary(lists:reverse([Chunk | BodyAcc])),
             Trailers};
        {quic_h3, Conn, {trailers, StreamId, T}} ->
            {Status, Headers,
             iolist_to_binary(lists:reverse(BodyAcc)), T};
        {quic_h3, Conn, {stream_end, StreamId}} ->
            {Status, Headers,
             iolist_to_binary(lists:reverse(BodyAcc)),
             Trailers};
        {quic_h3, Conn, _Other} ->
            collect_response(Conn, StreamId, Status, Headers, BodyAcc, Trailers)
    after ?REQUEST_TIMEOUT ->
        {error, timeout}
    end.

header(Name, Headers) ->
    LName = string:lowercase(Name),
    case lists:keyfind(LName, 1, normalize(Headers)) of
        {_, V} -> V;
        false  -> undefined
    end.

normalize(Hs) ->
    [{string:lowercase(N), V} || {N, V} <- Hs].
