%% @doc Test suite for example applications across HTTP/1.1, HTTP/2, and HTTP/3.
-module(livery_examples_SUITE).

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

%% Hello tests
-export([
    hello_root/1,
    hello_greet/1
]).

%% Stream tests
-export([
    stream_chunks/1,
    large_data/1,
    sse_events/1,
    stream_trailers/1
]).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        {group, hello_h1},
        {group, hello_h2},
        {group, hello_h3},
        %% Stream tests only run on H1 - H2 uses a different streaming interface
        {group, stream_h1}
    ].

groups() ->
    [
        {hello_h1, [sequence], hello_tests()},
        {hello_h2, [sequence], hello_tests()},
        {hello_h3, [sequence], hello_tests()},
        %% Stream tests only for H1 - livery's H2 streaming expects iterator-style
        %% functions rather than callback-style used by H1
        {stream_h1, [sequence], stream_tests()}
    ].

hello_tests() ->
    [
        hello_root,
        hello_greet
    ].

stream_tests() ->
    [
        stream_chunks,
        large_data,
        sse_events,
        stream_trailers
    ].

init_per_suite(Config) ->
    application:ensure_all_started(livery),
    %% Generate self-signed certs for H3 testing
    {CertDer, KeyDer} = generate_self_signed_cert(),
    [{cert_der, CertDer}, {key_der, KeyDer} | Config].

end_per_suite(_Config) ->
    application:stop(livery),
    ok.

init_per_group(hello_h1, Config) ->
    Port = get_free_port(),
    Routes = [
        {get, "/", hello_handler, #{}},
        {get, "/greet/:name", hello_handler, #{}}
    ],
    Router = livery_router:compile(Routes),
    {ok, _Pid} = livery:start_listener(hello_h1, #{
        port => Port,
        handler => livery_routing_handler,
        handler_opts => #{router => Router},
        num_acceptors => 1
    }),
    [{port, Port}, {protocol, h1} | Config];

init_per_group(hello_h2, Config) ->
    Port = get_free_port(),
    Routes = [
        {get, "/", hello_handler, #{}},
        {get, "/greet/:name", hello_handler, #{}}
    ],
    Router = livery_router:compile(Routes),
    {ok, _Pid} = livery:start_listener(hello_h2, #{
        port => Port,
        handler => livery_routing_handler,
        handler_opts => #{router => Router},
        num_acceptors => 1
    }),
    [{port, Port}, {protocol, h2} | Config];

init_per_group(hello_h3, Config) ->
    case is_quic_available() of
        true ->
            Port = get_free_port(),
            CertDer = ?config(cert_der, Config),
            KeyDer = ?config(key_der, Config),
            Routes = [
                {get, "/", hello_handler, #{}},
                {get, "/greet/:name", hello_handler, #{}}
            ],
            Router = livery_router:compile(Routes),
            {ok, _Pid} = livery:start_h3_listener(hello_h3, #{
                port => Port,
                handler => livery_routing_handler,
                handler_opts => #{router => Router},
                cert => CertDer,
                key => KeyDer
            }),
            [{port, Port}, {protocol, h3} | Config];
        false ->
            {skip, "QUIC library not available"}
    end;

init_per_group(stream_h1, Config) ->
    Port = get_free_port(),
    Routes = [
        {get, "/stream", stream_handler, #{action => stream}},
        {get, "/large", stream_handler, #{action => large}},
        {get, "/sse", stream_handler, #{action => sse}},
        {get, "/stream-with-trailers", stream_handler, #{action => trailers}}
    ],
    Router = livery_router:compile(Routes),
    {ok, _Pid} = livery:start_listener(stream_h1, #{
        port => Port,
        handler => livery_routing_handler,
        handler_opts => #{router => Router},
        num_acceptors => 1
    }),
    [{port, Port}, {protocol, h1} | Config];

init_per_group(_, Config) ->
    Config.

end_per_group(hello_h1, _Config) ->
    catch livery:stop_listener(hello_h1),
    ok;
end_per_group(hello_h2, _Config) ->
    catch livery:stop_listener(hello_h2),
    ok;
end_per_group(hello_h3, _Config) ->
    catch livery:stop_h3_listener(hello_h3),
    ok;
end_per_group(stream_h1, _Config) ->
    catch livery:stop_listener(stream_h1),
    ok;
end_per_group(_, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Hello Tests
%%====================================================================

hello_root(Config) ->
    Protocol = ?config(protocol, Config),
    Port = ?config(port, Config),
    Response = do_request(Protocol, Port, <<"GET">>, <<"/">>, Config),
    assert_status(Response, 200),
    assert_body_contains(Response, <<"Hello, World!">>).

hello_greet(Config) ->
    Protocol = ?config(protocol, Config),
    Port = ?config(port, Config),
    Response = do_request(Protocol, Port, <<"GET">>, <<"/greet/Alice">>, Config),
    assert_status(Response, 200),
    assert_body_contains(Response, <<"Hello, Alice!">>).

%%====================================================================
%% Stream Tests
%%====================================================================

stream_chunks(Config) ->
    Protocol = ?config(protocol, Config),
    Port = ?config(port, Config),
    Response = do_request(Protocol, Port, <<"GET">>, <<"/stream">>, Config),
    assert_status(Response, 200),
    assert_body_contains(Response, <<"chunk1">>),
    assert_body_contains(Response, <<"chunk2">>),
    assert_body_contains(Response, <<"chunk3">>).

large_data(Config) ->
    Protocol = ?config(protocol, Config),
    Port = ?config(port, Config),
    Response = do_request(Protocol, Port, <<"GET">>, <<"/large">>, Config),
    assert_status(Response, 200),
    %% Verify we got 1MB of data
    Body = get_body(Response),
    ?assertEqual(1024 * 1024, byte_size(Body)),
    %% Verify it's all X's
    Expected = binary:copy(<<"X">>, 1024 * 1024),
    ?assertEqual(Expected, Body).

sse_events(Config) ->
    Protocol = ?config(protocol, Config),
    Port = ?config(port, Config),
    Response = do_request(Protocol, Port, <<"GET">>, <<"/sse">>, Config),
    assert_status(Response, 200),
    assert_body_contains(Response, <<"event: message">>),
    assert_body_contains(Response, <<"data: event1">>),
    assert_body_contains(Response, <<"data: event2">>).

stream_trailers(Config) ->
    Port = ?config(port, Config),
    Response = do_h1_request(Port, <<"GET">>, <<"/stream-with-trailers">>),
    assert_status(Response, 200),
    assert_body_contains(Response, <<"data">>),
    assert_trailer(Response, <<"x-checksum">>, <<"abc123">>).

%%====================================================================
%% Protocol-Specific Request Helpers
%%====================================================================

do_request(h1, Port, Method, Path, _Config) ->
    do_h1_request(Port, Method, Path);
do_request(h2, Port, Method, Path, _Config) ->
    do_h2_request(Port, Method, Path);
do_request(h3, Port, Method, Path, Config) ->
    do_h3_request(Port, Method, Path, Config).

%%--------------------------------------------------------------------
%% HTTP/1.1
%%--------------------------------------------------------------------

do_h1_request(Port, Method, Path) ->
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    Request = [Method, <<" ">>, Path, <<" HTTP/1.1\r\n">>,
               <<"Host: localhost\r\n">>,
               <<"Connection: close\r\n">>,
               <<"\r\n">>],
    ok = gen_tcp:send(Socket, Request),
    Response = recv_all(Socket, <<>>, 30000),
    gen_tcp:close(Socket),
    parse_h1_response(Response).

recv_all(Socket, Acc, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            recv_all(Socket, <<Acc/binary, Data/binary>>, Timeout);
        {error, closed} ->
            Acc;
        {error, timeout} ->
            Acc
    end.

parse_h1_response(Response) ->
    case binary:split(Response, <<"\r\n\r\n">>) of
        [Headers, Body] ->
            {Status, HeaderList, Trailers} = parse_h1_headers(Headers),
            %% Check for chunked encoding and parse body/trailers
            IsChunked = lists:any(fun({K, V}) ->
                string:lowercase(binary_to_list(K)) =:= "transfer-encoding" andalso
                string:lowercase(binary_to_list(V)) =:= "chunked"
            end, HeaderList),
            if IsChunked ->
                {DecodedBody, ParsedTrailers} = decode_chunked_body(Body),
                #{status => Status, headers => HeaderList,
                  body => DecodedBody, trailers => Trailers ++ ParsedTrailers};
            true ->
                #{status => Status, headers => HeaderList, body => Body, trailers => Trailers}
            end;
        _ ->
            #{status => 0, headers => [], body => <<>>, trailers => []}
    end.

parse_h1_headers(HeaderData) ->
    Lines = binary:split(HeaderData, <<"\r\n">>, [global]),
    case Lines of
        [StatusLine | RestLines] ->
            Status = parse_status_line(StatusLine),
            Headers = parse_header_lines(RestLines),
            {Status, Headers, []};
        _ ->
            {0, [], []}
    end.

parse_status_line(Line) ->
    case re:run(Line, <<"HTTP/\\d\\.\\d (\\d+)">>, [{capture, [1], binary}]) of
        {match, [StatusBin]} -> binary_to_integer(StatusBin);
        _ -> 0
    end.

parse_header_lines(Lines) ->
    lists:filtermap(fun(Line) ->
        case binary:split(Line, <<": ">>) of
            [Name, Value] -> {true, {Name, Value}};
            _ -> false
        end
    end, Lines).

decode_chunked_body(Data) ->
    decode_chunked_body(Data, <<>>, []).

decode_chunked_body(Data, Acc, Trailers) ->
    case binary:split(Data, <<"\r\n">>) of
        [SizeLine, Rest] ->
            case parse_chunk_size(SizeLine) of
                0 ->
                    %% Final chunk, rest might be trailers
                    ParsedTrailers = parse_trailers(Rest),
                    {Acc, ParsedTrailers ++ Trailers};
                Size when is_integer(Size), Size > 0 ->
                    %% Extract chunk data
                    case Rest of
                        <<ChunkData:Size/binary, 13, 10, Remaining/binary>> ->
                            decode_chunked_body(Remaining, <<Acc/binary, ChunkData/binary>>, Trailers);
                        _ ->
                            %% Incomplete chunk, return what we have
                            {Acc, Trailers}
                    end;
                _ ->
                    {Acc, Trailers}
            end;
        _ ->
            {Acc, Trailers}
    end.

parse_chunk_size(Line) ->
    try
        %% Chunk size is hex, may have extensions after semicolon
        SizeStr = case binary:split(Line, <<";">>) of
            [S | _] -> S;
            _ -> Line
        end,
        list_to_integer(string:trim(binary_to_list(SizeStr)), 16)
    catch _:_ -> error
    end.

parse_trailers(Data) ->
    Lines = binary:split(Data, <<"\r\n">>, [global]),
    parse_header_lines(Lines).

%%--------------------------------------------------------------------
%% HTTP/2
%%--------------------------------------------------------------------

do_h2_request(Port, Method, Path) ->
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    %% Send connection preface
    Preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>,
    SettingsFrame = <<0:24, 4:8, 0:8, 0:1, 0:31>>,
    ok = gen_tcp:send(Socket, [Preface, SettingsFrame]),
    %% Receive server settings
    {ok, _ServerSettings} = gen_tcp:recv(Socket, 0, 5000),
    %% Send settings ACK
    SettingsAck = <<0:24, 4:8, 1:8, 0:1, 0:31>>,
    ok = gen_tcp:send(Socket, SettingsAck),
    %% Build HEADERS frame with HPACK encoded headers
    HeaderBlock = encode_h2_headers(Method, Path),
    HeaderLen = byte_size(HeaderBlock),
    %% HEADERS frame: type=1, flags=5 (END_HEADERS | END_STREAM for GET)
    Flags = case Method of
        <<"GET">> -> 5;  %% END_HEADERS | END_STREAM
        _ -> 4  %% END_HEADERS only
    end,
    HeadersFrame = <<HeaderLen:24, 1:8, Flags:8, 0:1, 1:31, HeaderBlock/binary>>,
    ok = gen_tcp:send(Socket, HeadersFrame),
    %% Receive response frames
    Response = recv_h2_response(Socket, 30000),
    gen_tcp:close(Socket),
    Response.

encode_h2_headers(Method, Path) ->
    %% Simple HPACK encoding using literal headers
    MethodEncoded = case Method of
        <<"GET">> -> <<16#82>>;  %% Indexed: :method: GET
        <<"POST">> -> <<16#83>>;  %% Indexed: :method: POST
        _ -> encode_literal_header(<<":method">>, Method)
    end,
    PathEncoded = case Path of
        <<"/">> -> <<16#84>>;  %% Indexed: :path: /
        _ -> encode_literal_header(<<":path">>, Path)
    end,
    SchemeEncoded = <<16#86>>,  %% Indexed: :scheme: http
    AuthorityEncoded = encode_literal_header(<<":authority">>, <<"localhost">>),
    <<MethodEncoded/binary, PathEncoded/binary, SchemeEncoded/binary, AuthorityEncoded/binary>>.

encode_literal_header(Name, Value) ->
    %% Literal header without indexing (HPACK RFC 7541 Section 6.2.2)
    %% Format: 0000 0000 (literal, new name) | H + Name Length | Name | H + Value Length | Value
    NameLen = byte_size(Name),
    ValueLen = byte_size(Value),
    <<16#00, 0:1, NameLen:7, Name/binary, 0:1, ValueLen:7, Value/binary>>.

recv_h2_response(Socket, Timeout) ->
    recv_h2_response(Socket, Timeout, #{status => 0, headers => [], body => <<>>, trailers => []}).

recv_h2_response(Socket, Timeout, Acc) ->
    case gen_tcp:recv(Socket, 9, Timeout) of
        {ok, <<Length:24, Type:8, Flags:8, _:1, StreamId:31>>} ->
            {ok, Payload} = if Length > 0 ->
                gen_tcp:recv(Socket, Length, Timeout);
            true ->
                {ok, <<>>}
            end,
            NewAcc = process_h2_frame(Type, Flags, StreamId, Payload, Acc),
            %% Check if we're done (END_STREAM flag on HEADERS or DATA)
            EndStream = (Flags band 1) =:= 1,
            if EndStream andalso (Type =:= 1 orelse Type =:= 0) ->
                NewAcc;
            true ->
                recv_h2_response(Socket, Timeout, NewAcc)
            end;
        {error, timeout} ->
            Acc;
        {error, _} ->
            Acc
    end.

process_h2_frame(0, _Flags, _StreamId, Data, Acc) ->
    %% DATA frame
    Body = maps:get(body, Acc),
    Acc#{body => <<Body/binary, Data/binary>>};
process_h2_frame(1, _Flags, _StreamId, HeaderBlock, Acc) ->
    %% HEADERS frame - decode HPACK
    {Status, Headers} = decode_h2_headers(HeaderBlock),
    CurrentStatus = maps:get(status, Acc),
    CurrentHeaders = maps:get(headers, Acc),
    if CurrentStatus =:= 0 ->
        Acc#{status => Status, headers => CurrentHeaders ++ Headers};
    true ->
        %% Trailing headers
        Trailers = maps:get(trailers, Acc),
        Acc#{trailers => Trailers ++ Headers}
    end;
process_h2_frame(4, _Flags, _StreamId, _Payload, Acc) ->
    %% SETTINGS frame - ignore
    Acc;
process_h2_frame(8, _Flags, _StreamId, _Payload, Acc) ->
    %% WINDOW_UPDATE frame - ignore
    Acc;
process_h2_frame(_, _Flags, _StreamId, _Payload, Acc) ->
    Acc.

decode_h2_headers(HeaderBlock) ->
    decode_h2_headers(HeaderBlock, 0, []).

decode_h2_headers(<<>>, Status, Headers) ->
    {Status, Headers};
decode_h2_headers(<<2#1:1, Index:7, Rest/binary>>, Status, Headers) when Index > 0 ->
    %% Indexed header field (RFC 7541 Section 6.1)
    {Name, Value} = get_indexed_header(Index),
    %% Only use first valid status found
    NewStatus = if Status =:= 0, Name =:= <<":status">> -> binary_to_integer(Value); true -> Status end,
    decode_h2_headers(Rest, NewStatus, [{Name, Value} | Headers]);
decode_h2_headers(<<2#01:2, NameIndex:6, Rest/binary>>, Status, Headers) when NameIndex > 0 ->
    %% Literal with incremental indexing, indexed name (RFC 7541 Section 6.2.1)
    Name = get_indexed_name(NameIndex),
    {Value, Rest2} = decode_string(Rest),
    %% Only use first valid status found
    NewStatus = if Status =:= 0, Name =:= <<":status">>, Value =/= <<>> -> binary_to_integer(Value); true -> Status end,
    decode_h2_headers(Rest2, NewStatus, [{Name, Value} | Headers]);
decode_h2_headers(<<2#01:2, 0:6, Rest/binary>>, Status, Headers) ->
    %% Literal with incremental indexing, new name
    {Name, Value, Rest2} = decode_literal_header_new_name(Rest),
    NewStatus = if Status =:= 0, Name =:= <<":status">>, Value =/= <<>> -> binary_to_integer(Value); true -> Status end,
    decode_h2_headers(Rest2, NewStatus, [{Name, Value} | Headers]);
decode_h2_headers(<<2#0000:4, NameIndex:4, Rest/binary>>, Status, Headers) when NameIndex > 0 ->
    %% Literal without indexing, indexed name
    Name = get_indexed_name(NameIndex),
    {Value, Rest2} = decode_string(Rest),
    NewStatus = if Status =:= 0, Name =:= <<":status">>, Value =/= <<>> -> binary_to_integer(Value); true -> Status end,
    decode_h2_headers(Rest2, NewStatus, [{Name, Value} | Headers]);
decode_h2_headers(<<2#0000:4, 0:4, Rest/binary>>, Status, Headers) ->
    %% Literal without indexing, new name
    {Name, Value, Rest2} = decode_literal_header_new_name(Rest),
    NewStatus = if Status =:= 0, Name =:= <<":status">>, Value =/= <<>> -> binary_to_integer(Value); true -> Status end,
    decode_h2_headers(Rest2, NewStatus, [{Name, Value} | Headers]);
decode_h2_headers(<<_:8, Rest/binary>>, Status, Headers) ->
    %% Skip unknown or dynamic table updates
    decode_h2_headers(Rest, Status, Headers).

decode_string(<<0:1, Len:7, Value:Len/binary, Rest/binary>>) ->
    %% Non-Huffman encoded string
    {Value, Rest};
decode_string(<<1:1, _Len:7, Rest/binary>>) ->
    %% Huffman encoded - skip for now (simplified)
    {<<>>, Rest};
decode_string(Data) ->
    {<<>>, Data}.

decode_literal_header_new_name(<<0:1, NameLen:7, Name:NameLen/binary, 0:1, ValueLen:7, Value:ValueLen/binary, Rest/binary>>) ->
    {Name, Value, Rest};
decode_literal_header_new_name(Data) ->
    {<<>>, <<>>, Data}.

%% Get name from static table for indexed name references
get_indexed_name(8) -> <<":status">>;
get_indexed_name(14) -> <<":status">>;  %% Both entries in static table
get_indexed_name(Index) ->
    {Name, _Value} = get_indexed_header(Index),
    Name.

get_indexed_header(8) -> {<<":status">>, <<"200">>};
get_indexed_header(9) -> {<<":status">>, <<"204">>};
get_indexed_header(10) -> {<<":status">>, <<"206">>};
get_indexed_header(11) -> {<<":status">>, <<"304">>};
get_indexed_header(12) -> {<<":status">>, <<"400">>};
get_indexed_header(13) -> {<<":status">>, <<"404">>};
get_indexed_header(14) -> {<<":status">>, <<"500">>};
get_indexed_header(_) -> {<<>>, <<>>}.

%%--------------------------------------------------------------------
%% HTTP/3
%%--------------------------------------------------------------------

do_h3_request(Port, Method, Path, Config) ->
    CertDer = ?config(cert_der, Config),
    KeyDer = ?config(key_der, Config),
    case quic_client_request(Port, Method, Path, CertDer, KeyDer) of
        {ok, Response} -> Response;
        {error, _Reason} ->
            %% Return empty response on error
            #{status => 0, headers => [], body => <<>>, trailers => []}
    end.

quic_client_request(Port, Method, Path, _CertDer, _KeyDer) ->
    %% Try to connect using quic library
    case code:ensure_loaded(quic) of
        {module, quic} ->
            do_quic_request(Port, Method, Path);
        _ ->
            %% QUIC library not available, skip H3 tests
            {error, quic_not_available}
    end.

do_quic_request(Port, Method, Path) ->
    %% Connect to QUIC server
    QuicOpts = #{
        alpn => [<<"h3">>],
        verify => none
    },
    case quic:connect("127.0.0.1", Port, QuicOpts) of
        {ok, Conn} ->
            %% Open a bidirectional stream
            {ok, Stream} = quic:open_stream(Conn, bidirectional),
            %% Send HTTP/3 request using QPACK
            RequestFrames = build_h3_request(Method, Path),
            ok = quic:send(Stream, RequestFrames),
            ok = quic:shutdown_stream(Stream, write),
            %% Receive response
            Response = recv_h3_response(Stream, <<>>, 30000),
            quic:close(Conn),
            {ok, Response};
        {error, Reason} ->
            {error, Reason}
    end.

build_h3_request(Method, Path) ->
    %% Build HEADERS frame with QPACK encoded headers
    %% QPACK uses similar encoding to HPACK
    HeaderBlock = encode_qpack_headers(Method, Path),
    HeadersLen = byte_size(HeaderBlock),
    %% HTTP/3 HEADERS frame: type=0x01
    HeadersFrame = <<1:8, HeadersLen:8, HeaderBlock/binary>>,
    HeadersFrame.

encode_qpack_headers(Method, Path) ->
    %% Simple QPACK encoding - literal headers without indexing
    %% Required pseudo-headers: :method, :scheme, :authority, :path
    MethodHeader = encode_qpack_literal(<<":method">>, Method),
    SchemeHeader = encode_qpack_literal(<<":scheme">>, <<"https">>),
    AuthorityHeader = encode_qpack_literal(<<":authority">>, <<"localhost">>),
    PathHeader = encode_qpack_literal(<<":path">>, Path),
    <<0:8, 0:8,  %% Required insert count and base
      MethodHeader/binary,
      SchemeHeader/binary,
      AuthorityHeader/binary,
      PathHeader/binary>>.

encode_qpack_literal(Name, Value) ->
    NameLen = byte_size(Name),
    ValueLen = byte_size(Value),
    <<2#00100000:8, NameLen:7, Name/binary, ValueLen:7, Value/binary>>.

recv_h3_response(Stream, Acc, Timeout) ->
    case quic:recv(Stream, Timeout) of
        {ok, Data} ->
            NewAcc = <<Acc/binary, Data/binary>>,
            %% Try to parse H3 frames
            case try_parse_h3_response(NewAcc) of
                {complete, Response} ->
                    Response;
                {incomplete, _} ->
                    recv_h3_response(Stream, NewAcc, Timeout)
            end;
        {error, fin} ->
            %% Stream finished, parse what we have
            {complete, Response} = try_parse_h3_response(Acc),
            Response;
        {error, _} ->
            #{status => 0, headers => [], body => <<>>, trailers => []}
    end.

try_parse_h3_response(Data) ->
    try_parse_h3_response(Data, #{status => 0, headers => [], body => <<>>, trailers => []}).

try_parse_h3_response(<<>>, Acc) ->
    {complete, Acc};
try_parse_h3_response(<<Type:8, Length:8, Payload:Length/binary, Rest/binary>>, Acc) ->
    NewAcc = process_h3_frame(Type, Payload, Acc),
    try_parse_h3_response(Rest, NewAcc);
try_parse_h3_response(Data, Acc) when byte_size(Data) < 2 ->
    {incomplete, Acc};
try_parse_h3_response(_Data, Acc) ->
    {complete, Acc}.

process_h3_frame(0, Data, Acc) ->
    %% DATA frame
    Body = maps:get(body, Acc),
    Acc#{body => <<Body/binary, Data/binary>>};
process_h3_frame(1, HeaderBlock, Acc) ->
    %% HEADERS frame
    {Status, Headers} = decode_qpack_headers(HeaderBlock),
    CurrentStatus = maps:get(status, Acc),
    if CurrentStatus =:= 0 ->
        Acc#{status => Status, headers => Headers};
    true ->
        Trailers = maps:get(trailers, Acc),
        Acc#{trailers => Trailers ++ Headers}
    end;
process_h3_frame(_, _Data, Acc) ->
    Acc.

decode_qpack_headers(<<_InsertCount:8, _Base:8, Rest/binary>>) ->
    decode_qpack_headers_loop(Rest, 0, []);
decode_qpack_headers(_) ->
    {0, []}.

decode_qpack_headers_loop(<<>>, Status, Headers) ->
    {Status, lists:reverse(Headers)};
decode_qpack_headers_loop(<<2#00100000:8, NameLen:7, Name:NameLen/binary,
                            ValueLen:7, Value:ValueLen/binary, Rest/binary>>, Status, Headers) ->
    NewStatus = if Name =:= <<":status">> -> binary_to_integer(Value); true -> Status end,
    decode_qpack_headers_loop(Rest, NewStatus, [{Name, Value} | Headers]);
decode_qpack_headers_loop(<<_:8, Rest/binary>>, Status, Headers) ->
    decode_qpack_headers_loop(Rest, Status, Headers).

%%====================================================================
%% Assertion Helpers
%%====================================================================

assert_status(#{status := Status}, Expected) ->
    ?assertEqual(Expected, Status).

assert_body_contains(#{body := Body}, Expected) ->
    ?assertMatch({match, _}, re:run(Body, Expected)).

assert_trailer(#{trailers := Trailers}, Name, Value) ->
    Found = lists:any(fun({K, V}) ->
        string:lowercase(binary_to_list(K)) =:= string:lowercase(binary_to_list(Name)) andalso
        V =:= Value
    end, Trailers),
    ?assert(Found).

get_body(#{body := Body}) -> Body.

%%====================================================================
%% Certificate Generation
%%====================================================================

generate_self_signed_cert() ->
    %% Use openssl to generate self-signed cert and key in DER format
    TmpDir = filename:join(["/tmp", "livery_test_" ++ integer_to_list(erlang:unique_integer([positive]))]),
    case file:make_dir(TmpDir) of
        ok -> ok;
        {error, eexist} -> ok
    end,
    KeyFile = filename:join(TmpDir, "key.der"),
    CertFile = filename:join(TmpDir, "cert.der"),
    KeyPemFile = filename:join(TmpDir, "key.pem"),
    %% Generate RSA private key
    Cmd1 = io_lib:format("openssl genrsa -out ~s 2048 2>/dev/null", [KeyPemFile]),
    os:cmd(Cmd1),
    %% Convert key to DER format
    Cmd2 = io_lib:format("openssl rsa -in ~s -outform DER -out ~s 2>/dev/null", [KeyPemFile, KeyFile]),
    os:cmd(Cmd2),
    %% Generate self-signed certificate in DER format
    Cmd3 = io_lib:format(
        "openssl req -new -x509 -key ~s -outform DER -out ~s -days 365 -subj '/CN=localhost' 2>/dev/null",
        [KeyPemFile, CertFile]),
    os:cmd(Cmd3),
    %% Read the DER files
    {ok, CertDer} = file:read_file(CertFile),
    {ok, KeyDer} = file:read_file(KeyFile),
    %% Clean up temp files
    file:delete(KeyFile),
    file:delete(CertFile),
    file:delete(KeyPemFile),
    file:del_dir(TmpDir),
    {CertDer, KeyDer}.

%%====================================================================
%% Utility Functions
%%====================================================================

is_quic_available() ->
    case code:ensure_loaded(quic) of
        {module, quic} ->
            erlang:function_exported(quic, connect, 3);
        _ ->
            false
    end.

get_free_port() ->
    {ok, Socket} = gen_tcp:listen(0, []),
    {ok, Port} = inet:port(Socket),
    gen_tcp:close(Socket),
    Port.
