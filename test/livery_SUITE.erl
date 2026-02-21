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
    streaming_response_with_trailers/1,
    %% HTTP/2 tests
    h2_prior_knowledge/1,
    h2_get_request/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [
        {group, http},
        {group, h2}
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
        ]},
        {h2, [sequence], [
            h2_prior_knowledge,
            h2_get_request
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
init_per_group(h2, Config) ->
    Port = get_free_port(),
    {ok, _Pid} = livery:start_listener(test_h2, #{
        port => Port,
        handler => test_handler,
        num_acceptors => 1
    }),
    [{h2_port, Port} | Config];
init_per_group(_, Config) ->
    Config.

end_per_group(http, _Config) ->
    livery:stop_listener(test_http),
    ok;
end_per_group(h2, _Config) ->
    livery:stop_listener(test_h2),
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

%% HTTP/2 tests

h2_prior_knowledge(Config) ->
    Port = ?config(h2_port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    %% Send HTTP/2 connection preface
    Preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>,
    %% Send empty SETTINGS frame
    SettingsFrame = <<0:24, 4:8, 0:8, 0:1, 0:31>>,
    ok = gen_tcp:send(Socket, [Preface, SettingsFrame]),
    %% Should receive server SETTINGS
    {ok, Response} = gen_tcp:recv(Socket, 0, 5000),
    gen_tcp:close(Socket),
    %% Verify we received a SETTINGS frame (type 0x04)
    <<_Length:24, Type:8, _Rest/binary>> = Response,
    ?assertEqual(4, Type).  %% SETTINGS frame type

h2_get_request(Config) ->
    Port = ?config(h2_port, Config),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    %% Send HTTP/2 connection preface
    Preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>,
    %% Send empty SETTINGS frame
    SettingsFrame = <<0:24, 4:8, 0:8, 0:1, 0:31>>,
    ok = gen_tcp:send(Socket, [Preface, SettingsFrame]),
    %% Receive and acknowledge server SETTINGS
    {ok, _ServerSettings} = gen_tcp:recv(Socket, 0, 5000),
    %% Send SETTINGS ACK
    SettingsAck = <<0:24, 4:8, 1:8, 0:1, 0:31>>,
    ok = gen_tcp:send(Socket, SettingsAck),
    %% Send HEADERS frame for GET /
    %% Using HPACK literal header encoding
    %% :method: GET, :path: /, :scheme: http, :authority: localhost
    HeaderBlock = <<
        16#82,  %% :method: GET (indexed)
        16#84,  %% :path: / (indexed)
        16#86,  %% :scheme: http (indexed)
        16#41, 9, "localhost"  %% :authority: localhost (literal)
    >>,
    HeaderLen = byte_size(HeaderBlock),
    %% HEADERS frame: length, type=1, flags=5 (END_HEADERS | END_STREAM), stream_id=1
    HeadersFrame = <<HeaderLen:24, 1:8, 5:8, 0:1, 1:31, HeaderBlock/binary>>,
    ok = gen_tcp:send(Socket, HeadersFrame),
    %% Receive response (may include SETTINGS ACK + HEADERS + DATA)
    Response = recv_h2_frames(Socket, <<>>, 5000),
    gen_tcp:close(Socket),
    %% Verify we received a HEADERS frame (type 0x01) with status 200
    ?assert(has_h2_headers_frame(Response)).

%% Helpers

recv_h2_frames(Socket, Acc, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            NewAcc = <<Acc/binary, Data/binary>>,
            %% Check if we have enough data (at least 9 bytes for frame header + some payload)
            case byte_size(NewAcc) >= 20 of
                true -> NewAcc;
                false -> recv_h2_frames(Socket, NewAcc, Timeout)
            end;
        {error, _} ->
            Acc
    end.

has_h2_headers_frame(Data) ->
    %% Look for a HEADERS frame (type 1) in the data
    has_h2_headers_frame(Data, 0).

has_h2_headers_frame(<<>>, _) -> false;
has_h2_headers_frame(Data, Offset) when Offset >= byte_size(Data) - 9 -> false;
has_h2_headers_frame(Data, Offset) ->
    <<_:Offset/binary, Length:24, Type:8, _Flags:8, _:1, _StreamId:31, _/binary>> = Data,
    case Type of
        1 -> true;  %% HEADERS frame
        _ ->
            %% Skip to next frame
            NextOffset = Offset + 9 + Length,
            has_h2_headers_frame(Data, NextOffset)
    end.

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
