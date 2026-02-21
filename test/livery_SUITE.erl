%% @doc End-to-end test suite for Livery HTTP server.
-module(livery_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([
    suite/0,
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Test cases
-export([
    start_stop_listener/1,
    get_request/1,
    post_with_body/1,
    json_response/1,
    not_found/1,
    query_string/1,
    custom_status/1,
    multiple_headers/1,
    keepalive/1,
    connection_close/1,
    http10_close/1,
    concurrent_connections/1,
    bad_request/1,
    %% Chunked transfer encoding tests
    chunked_request_body/1,
    chunked_request_multiple_chunks/1,
    streaming_response/1,
    streaming_response_with_trailers/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        {group, http}
    ].

groups() ->
    [
        {http, [sequence], [
            start_stop_listener,
            get_request,
            post_with_body,
            json_response,
            not_found,
            query_string,
            custom_status,
            multiple_headers,
            keepalive,
            connection_close,
            http10_close,
            concurrent_connections,
            bad_request,
            %% Chunked transfer encoding tests
            chunked_request_body,
            chunked_request_multiple_chunks,
            streaming_response,
            streaming_response_with_trailers
        ]}
    ].

init_per_suite(Config) ->
    application:ensure_all_started(livery),
    Config.

end_per_suite(_Config) ->
    application:stop(livery),
    ok.

init_per_group(http, Config) ->
    Port = get_free_port(),
    {ok, _Pid} = livery:start_listener(test_http, #{
        port => Port,
        handler => test_handler,
        num_acceptors => 1
    }),
    [{port, Port} | Config];
init_per_group(_, Config) ->
    Config.

end_per_group(http, _Config) ->
    livery:stop_listener(test_http),
    ok;
end_per_group(_, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%% Test cases

start_stop_listener(_Config) ->
    Port = get_free_port(),
    {ok, _Pid} = livery:start_listener(test_start_stop, #{
        port => Port,
        handler => test_handler
    }),
    ?assert(lists:member(test_start_stop, livery:which_listeners())),
    ok = livery:stop_listener(test_start_stop),
    ?assertNot(lists:member(test_start_stop, livery:which_listeners())).

get_request(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, <<"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.1 200 OK">>)),
    ?assertMatch({match, _}, re:run(Response, <<"Hello, World!">>)).

post_with_body(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    Body = <<"test body content">>,
    Request = [
        <<"POST /echo HTTP/1.1\r\n">>,
        <<"Host: localhost\r\n">>,
        <<"Content-Type: text/plain\r\n">>,
        <<"Content-Length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n">>,
        <<"\r\n">>,
        Body
    ],
    ok = gen_tcp:send(Socket, Request),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.1 200 OK">>)),
    ?assertMatch({match, _}, re:run(Response, Body)).

json_response(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, <<"GET /json HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"application/json">>)),
    ?assertMatch({match, _}, re:run(Response, <<"\"message\":\"hello\"">>)).

not_found(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, <<"GET /nonexistent HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.1 404">>)).

query_string(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, <<"GET /query?foo=bar&baz=qux HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"foo=bar&baz=qux">>)).

custom_status(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, <<"GET /status/201 HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.1 201 Created">>)).

multiple_headers(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    Request = [
        <<"GET /headers HTTP/1.1\r\n">>,
        <<"Host: localhost\r\n">>,
        <<"X-Custom: value1\r\n">>,
        <<"X-Another: value2\r\n">>,
        <<"\r\n">>
    ],
    ok = gen_tcp:send(Socket, Request),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"x-custom: value1">>)),
    ?assertMatch({match, _}, re:run(Response, <<"x-another: value2">>)).

keepalive(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),

    %% First request
    ok = gen_tcp:send(Socket, <<"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    {ok, Response1} = gen_tcp:recv(Socket, 0, 5000),
    ?assertMatch({match, _}, re:run(Response1, <<"HTTP/1.1 200 OK">>)),

    %% Second request on same connection
    ok = gen_tcp:send(Socket, <<"GET /json HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    {ok, Response2} = gen_tcp:recv(Socket, 0, 5000),
    ?assertMatch({match, _}, re:run(Response2, <<"application/json">>)),

    gen_tcp:close(Socket).

connection_close(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    Request = [
        <<"GET / HTTP/1.1\r\n">>,
        <<"Host: localhost\r\n">>,
        <<"Connection: close\r\n">>,
        <<"\r\n">>
    ],
    ok = gen_tcp:send(Socket, Request),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.1 200 OK">>)),
    ?assertMatch({match, _}, re:run(Response, <<"connection: close">>, [caseless])),

    %% Connection should be closed by server
    timer:sleep(100),
    ?assertEqual({error, closed}, gen_tcp:recv(Socket, 0, 1000)).

http10_close(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    Request = <<"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n">>,
    ok = gen_tcp:send(Socket, Request),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.0 200 OK">>)),

    %% HTTP/1.0 defaults to close
    timer:sleep(100),
    ?assertEqual({error, closed}, gen_tcp:recv(Socket, 0, 1000)).

concurrent_connections(Config) ->
    Port = ?config(port, Config),
    Self = self(),

    %% Spawn 10 concurrent connections
    Pids = [spawn_link(fun() ->
        {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
        ok = gen_tcp:send(Socket, <<"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
        {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
        gen_tcp:close(Socket),
        Self ! {self(), Response}
    end) || _ <- lists:seq(1, 10)],

    %% Collect responses
    Responses = [receive {Pid, R} -> R end || Pid <- Pids],

    %% All should be successful
    lists:foreach(fun(Response) ->
        ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.1 200 OK">>))
    end, Responses).

bad_request(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    %% Invalid request - missing HTTP version
    ok = gen_tcp:send(Socket, <<"GET /\r\n\r\n">>),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.1 400">>)).

%% Chunked transfer encoding tests

chunked_request_body(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    %% Send a chunked request: "hello world" in two chunks
    Request = [
        <<"POST /chunked-echo HTTP/1.1\r\n">>,
        <<"Host: localhost\r\n">>,
        <<"Content-Type: text/plain\r\n">>,
        <<"Transfer-Encoding: chunked\r\n">>,
        <<"\r\n">>,
        <<"5\r\nhello\r\n">>,
        <<"6\r\n world\r\n">>,
        <<"0\r\n\r\n">>
    ],
    ok = gen_tcp:send(Socket, Request),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.1 200 OK">>)),
    ?assertMatch({match, _}, re:run(Response, <<"hello world">>)),
    ?assertMatch({match, _}, re:run(Response, <<"x-body-length: 11">>)).

chunked_request_multiple_chunks(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    %% Send multiple chunks with hex sizes
    Request = [
        <<"POST /chunked-echo HTTP/1.1\r\n">>,
        <<"Host: localhost\r\n">>,
        <<"Content-Type: text/plain\r\n">>,
        <<"Transfer-Encoding: chunked\r\n">>,
        <<"\r\n">>,
        <<"a\r\n0123456789\r\n">>,   %% 10 bytes (0xa)
        <<"5\r\nabcde\r\n">>,         %% 5 bytes
        <<"0\r\n\r\n">>
    ],
    ok = gen_tcp:send(Socket, Request),
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.1 200 OK">>)),
    ?assertMatch({match, _}, re:run(Response, <<"0123456789abcde">>)),
    ?assertMatch({match, _}, re:run(Response, <<"x-body-length: 15">>)).

streaming_response(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, <<"GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    %% Read all data until we see the final chunk marker
    Response = recv_until_end(Socket, <<>>, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.1 200 OK">>)),
    ?assertMatch({match, _}, re:run(Response, <<"transfer-encoding: chunked">>, [caseless])),
    %% Should contain the chunks
    ?assertMatch({match, _}, re:run(Response, <<"chunk1">>)),
    ?assertMatch({match, _}, re:run(Response, <<"chunk2">>)),
    ?assertMatch({match, _}, re:run(Response, <<"chunk3">>)),
    %% Should end with final chunk
    ?assertMatch({match, _}, re:run(Response, <<"0\r\n\r\n">>)).

streaming_response_with_trailers(Config) ->
    Port = ?config(port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, <<"GET /stream-with-trailers HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
    Response = recv_until_end(Socket, <<>>, 5000),
    gen_tcp:close(Socket),
    ?assertMatch({match, _}, re:run(Response, <<"HTTP/1.1 200 OK">>)),
    ?assertMatch({match, _}, re:run(Response, <<"transfer-encoding: chunked">>, [caseless])),
    ?assertMatch({match, _}, re:run(Response, <<"data">>)),
    %% Should have trailer
    ?assertMatch({match, _}, re:run(Response, <<"x-checksum: abc123">>)).

%% Helpers

get_free_port() ->
    {ok, Socket} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(Socket),
    gen_tcp:close(Socket),
    Port.

%% Receive data until we see the final chunk marker "0\r\n" followed by trailers and "\r\n"
recv_until_end(Socket, Acc, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            NewAcc = <<Acc/binary, Data/binary>>,
            %% Check if we've received the final chunk
            case binary:match(NewAcc, <<"0\r\n\r\n">>) of
                nomatch ->
                    %% Also check for trailers pattern
                    case binary:match(NewAcc, <<"\r\n0\r\n">>) of
                        nomatch ->
                            recv_until_end(Socket, NewAcc, Timeout);
                        _ ->
                            %% Found final chunk, but may need to read trailers
                            case binary:match(NewAcc, <<"\r\n\r\n">>, [{scope, {byte_size(NewAcc) - 10, 10}}]) of
                                nomatch ->
                                    recv_until_end(Socket, NewAcc, Timeout);
                                _ ->
                                    NewAcc
                            end
                    end;
                _ ->
                    NewAcc
            end;
        {error, _} ->
            Acc
    end.
