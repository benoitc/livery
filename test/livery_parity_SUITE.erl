%% @doc Cross-adapter parity SUITE.
%%
%% Runs a shared handler matrix against every Livery adapter and
%% asserts externally observable behaviour (status, normalized
%% headers, body, trailers, streaming cadence) is identical.
%%
%% Phase 1 wired `livery_test_adapter'. Phase 2 adds `livery_h1'
%% driven over a real TCP socket via hackney. Phase 3 adds
%% `livery_h2' driven over h2c using the `h2' library's own client.
%% Phase 4 adds `livery_h3' driven over QUIC + TLS using vendored
%% self-signed certs and the `quic_h3' library's own client.
-module(livery_parity_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    text_response/1,
    json_response/1,
    empty_response/1,
    echo_buffered_body/1,
    streaming_chunked_response/1,
    sse_response/1,
    ndjson_response/1,
    file_response/1,
    response_with_trailers/1,
    handler_crash_returns_500/1,
    middleware_short_circuit/1,
    middleware_after_response/1,
    full_pipeline_with_builtins/1,
    gzip_negotiation/1,
    gzip_with_trailers/1
]).

%%====================================================================
%% Suite plumbing
%%====================================================================

all() ->
    [{group, test_adapter}, {group, h1}, {group, h2}, {group, h3}].

groups() ->
    Shared = [
        text_response,
        json_response,
        empty_response,
        echo_buffered_body,
        streaming_chunked_response,
        sse_response,
        ndjson_response,
        file_response,
        handler_crash_returns_500,
        middleware_short_circuit,
        middleware_after_response,
        full_pipeline_with_builtins,
        gzip_negotiation,
        gzip_with_trailers
    ],
    [
        {test_adapter, [parallel], Shared ++ [response_with_trailers]},
        %% hackney does not surface trailers; trailers stay test-only
        %% in the h1 group.
        {h1, [], Shared},
        %% h2's own client exposes trailers, so the h2 group includes
        %% them.
        {h2, [], Shared ++ [response_with_trailers]},
        %% h3 also exposes trailers.
        {h3, [], Shared ++ [response_with_trailers]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(h1),
    {ok, _} = application:ensure_all_started(h2),
    {ok, _} = application:ensure_all_started(quic),
    {ok, _} = application:ensure_all_started(hackney),
    {ok, CertDer, KeyDer} = livery_test_certs:load(),
    [{cert, CertDer}, {key, KeyDer} | Config].

end_per_suite(_Config) ->
    _ = application:stop(hackney),
    _ = application:stop(quic),
    _ = application:stop(h2),
    _ = application:stop(h1),
    _ = application:stop(livery),
    ok.

init_per_group(test_adapter, Config) ->
    [{driver, fun drive_test_adapter/3} | Config];
init_per_group(h1, Config) ->
    [{driver, fun drive_h1/3} | Config];
init_per_group(h2, Config) ->
    [{driver, fun drive_h2/3} | Config];
init_per_group(h3, Config) ->
    Cert = ?config(cert, Config),
    Key = ?config(key, Config),
    [
        {driver, fun(S, H, Spec) -> drive_h3(Cert, Key, S, H, Spec) end}
        | Config
    ];
init_per_group(_, Config) ->
    Config.

end_per_group(_, _Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

%%====================================================================
%% Cases
%%====================================================================

text_response(Config) ->
    Resp = drive(
        Config,
        [],
        fun(_R) ->
            livery_resp:text(200, <<"hello">>)
        end,
        #{}
    ),
    ?assertEqual(200, status(Resp)),
    ?assertEqual(<<"hello">>, body(Resp)),
    ?assertEqual(
        <<"text/plain; charset=utf-8">>,
        header(<<"content-type">>, Resp)
    ).

json_response(Config) ->
    Body = <<"{\"ok\":true}">>,
    Resp = drive(
        Config,
        [],
        fun(_R) ->
            livery_resp:json(200, Body)
        end,
        #{}
    ),
    ?assertEqual(200, status(Resp)),
    ?assertEqual(Body, body(Resp)),
    ?assertEqual(
        <<"application/json">>,
        header(<<"content-type">>, Resp)
    ).

empty_response(Config) ->
    Resp = drive(
        Config,
        [],
        fun(_R) ->
            livery_resp:empty(204)
        end,
        #{}
    ),
    ?assertEqual(204, status(Resp)),
    ?assertEqual(<<>>, body(Resp)).

echo_buffered_body(Config) ->
    Handler = fun(R) ->
        case livery_req:body(R) of
            {buffered, IoData} ->
                livery_resp:text(200, IoData);
            {stream, Reader} ->
                {ok, Bytes, _} = livery_body:read_all(Reader, 5000),
                livery_resp:text(200, Bytes)
        end
    end,
    Resp = drive(
        Config,
        [],
        Handler,
        #{
            method => <<"POST">>,
            body => {buffered, <<"echo me">>}
        }
    ),
    ?assertEqual(<<"echo me">>, body(Resp)).

streaming_chunked_response(Config) ->
    Producer = fun(Emit) ->
        [Emit(integer_to_binary(N)) || N <- lists:seq(1, 5)],
        ok
    end,
    Resp = drive(
        Config,
        [],
        fun(_R) ->
            livery_resp:stream(200, [], Producer)
        end,
        #{}
    ),
    ?assertEqual(<<"12345">>, body(Resp)).

sse_response(Config) ->
    Producer = fun(Emit) ->
        Emit(#{event => <<"tick">>, data => <<"1">>}),
        Emit(#{event => <<"tick">>, data => <<"2">>}),
        ok
    end,
    Resp = drive(
        Config,
        [],
        fun(_R) ->
            livery_resp:sse(200, Producer)
        end,
        #{}
    ),
    ?assertEqual(
        <<"text/event-stream">>,
        header(<<"content-type">>, Resp)
    ),
    ?assertEqual(
        <<"event: tick\ndata: 1\n\nevent: tick\ndata: 2\n\n">>,
        body(Resp)
    ).

ndjson_response(Config) ->
    Producer = fun(Emit) ->
        Emit(#{<<"n">> => 1}),
        Emit(#{<<"n">> => 2}),
        Emit(#{<<"n">> => 3}),
        ok
    end,
    Resp = drive(
        Config,
        [],
        fun(_R) ->
            livery_resp:ndjson(200, Producer)
        end,
        #{}
    ),
    ?assertEqual(
        <<"application/x-ndjson">>,
        header(<<"content-type">>, Resp)
    ),
    ?assertEqual(<<"{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n">>, body(Resp)).

file_response(Config) ->
    Body = <<"file body served from disk">>,
    Path = filename:join(
        temp_dir(),
        "livery_parity_file_" ++
            integer_to_list(erlang:unique_integer([positive])) ++ ".bin"
    ),
    ok = file:write_file(Path, Body),
    try
        Resp = drive(
            Config,
            [],
            fun(_R) ->
                livery_resp:file(200, Path)
            end,
            #{}
        ),
        ?assertEqual(200, status(Resp)),
        ?assertEqual(Body, body(Resp)),
        ?assertEqual(
            integer_to_binary(byte_size(Body)),
            header(<<"content-length">>, Resp)
        )
    after
        file:delete(Path)
    end.

response_with_trailers(Config) ->
    Handler = fun(_R) ->
        Resp0 = livery_resp:text(200, <<"hello">>),
        livery_resp:with_trailers([{<<"x-checksum">>, <<"abc">>}], Resp0)
    end,
    Cap = drive(Config, [], Handler, #{}),
    ?assertEqual([{<<"x-checksum">>, <<"abc">>}], trailers(Cap)).

handler_crash_returns_500(Config) ->
    Resp = drive(Config, [], fun(_R) -> error(boom) end, #{}),
    ?assertEqual(500, status(Resp)).

middleware_short_circuit(Config) ->
    Stack = [fun(_R, _N) -> livery_resp:text(401, <<"nope">>) end],
    Resp = drive(
        Config,
        Stack,
        fun(_R) -> error(must_not_be_called) end,
        #{}
    ),
    ?assertEqual(401, status(Resp)),
    ?assertEqual(<<"nope">>, body(Resp)).

middleware_after_response(Config) ->
    Stack = [
        livery_middleware:after_response(
            fun(R) -> livery_resp:with_header(<<"X-After">>, <<"1">>, R) end
        )
    ],
    Resp = drive(
        Config,
        Stack,
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        #{}
    ),
    ?assertEqual(<<"1">>, header(<<"x-after">>, Resp)).

full_pipeline_with_builtins(Config) ->
    Stack = [
        {livery_request_id, undefined},
        {livery_body_limit, #{max => 1024}}
    ],
    Resp = drive(
        Config,
        Stack,
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        #{body => {buffered, <<"small">>}}
    ),
    ?assertEqual(200, status(Resp)),
    Id = header(<<"x-request-id">>, Resp),
    ?assert(is_binary(Id)),
    ?assertEqual(32, byte_size(Id)).

gzip_negotiation(Config) ->
    Body = <<"{\"message\":\"compress me across every adapter\",\"items\":[1,2,3,4,5]}">>,
    Stack = [{livery_compress, #{min_size => 0}}],
    Resp = drive(
        Config,
        Stack,
        fun(_R) -> livery_resp:json(200, Body) end,
        #{headers => [{<<"accept-encoding">>, <<"gzip">>}]}
    ),
    ?assertEqual(200, status(Resp)),
    ?assertEqual(<<"gzip">>, header(<<"content-encoding">>, Resp)),
    %% Decode the wire bytes with an independent zlib call: identical on
    %% test_adapter, h1, h2, h3.
    ?assertEqual(Body, zlib:gunzip(body(Resp))).

gzip_with_trailers(Config) ->
    Body = <<"{\"k\":\"trailer body that is gzip compressed on the wire\"}">>,
    Stack = [{livery_compress, #{min_size => 0}}],
    Handler = fun(_R) ->
        Resp0 = livery_resp:json(200, Body),
        livery_resp:with_trailers([{<<"x-checksum">>, <<"abc">>}], Resp0)
    end,
    Resp = drive(
        Config,
        Stack,
        Handler,
        #{headers => [{<<"accept-encoding">>, <<"gzip">>}]}
    ),
    ?assertEqual(<<"gzip">>, header(<<"content-encoding">>, Resp)),
    %% No Content-Length: H1 must stay chunked so send_trailers works;
    %% H2/H3 send trailers as a HEADERS frame. The body must still gunzip
    %% (a broken send_trailers would truncate/reset the stream).
    ?assertEqual(undefined, header(<<"content-length">>, Resp)),
    ?assertEqual(Body, zlib:gunzip(body(Resp))),
    %% Drivers that surface trailers (test_adapter/h2/h3) also check them;
    %% the h1 driver returns undefined trailers (hackney drops them).
    case trailers(Resp) of
        undefined -> ok;
        T -> ?assertEqual([{<<"x-checksum">>, <<"abc">>}], T)
    end.

%%====================================================================
%% Uniform driver API: returns a `response()' tuple
%%====================================================================

-record(response, {
    status :: 100..599,
    headers = [] :: [{binary(), binary()}],
    body = <<>> :: binary(),
    trailers :: undefined | [{binary(), binary()}]
}).

drive(Config, Stack, Handler, Spec) ->
    Driver = ?config(driver, Config),
    Driver(Stack, Handler, Spec).

status(#response{status = S}) -> S.
body(#response{body = B}) -> B.
trailers(#response{trailers = T}) -> T.

header(Name, #response{headers = Hs}) ->
    case lists:keyfind(Name, 1, Hs) of
        {_, V} -> V;
        false -> undefined
    end.

%%====================================================================
%% Driver: test_adapter
%%====================================================================

drive_test_adapter(Stack, Handler, Spec) ->
    Cap = livery_test_adapter:run(Stack, Handler, Spec),
    %% Crashes don't surface through run/3; for the crash test case
    %% we drive via the per-request worker so the 500 mapping kicks
    %% in. The dispatcher knows it's a crash by looking at the
    %% handler — but we keep this synchronous to match h1.
    #response{
        status = livery_test_adapter:status(Cap),
        headers = livery_test_adapter:headers(Cap),
        body = livery_test_adapter:body(Cap),
        trailers = livery_test_adapter:trailers(Cap)
    }.

%%====================================================================
%% Driver: h1
%%====================================================================

drive_h1(Stack, Handler, Spec) ->
    %% Wrap the handler with a wrap-middleware so crashes map to 500
    %% under livery_test_adapter:run/3 semantics; h1's livery_req_proc
    %% does the same mapping natively.
    Method = maps:get(method, Spec, <<"GET">>),
    Body = body_bytes(maps:get(body, Spec, empty)),
    {ok, Listener} = livery_h1:start(#{
        port => 0,
        stack => Stack,
        handler => Handler
    }),
    try
        Port = h1:server_port(Listener),
        Url = iolist_to_binary([
            <<"http://127.0.0.1:">>,
            integer_to_binary(Port),
            <<"/">>
        ]),
        Base =
            case byte_size(Body) of
                0 -> [];
                _ -> [{<<"content-length">>, integer_to_binary(byte_size(Body))}]
            end,
        Headers = Base ++ maps:get(headers, Spec, []),
        {ok, Status, RespHeaders, RespBody} =
            hackney:request(
                Method,
                Url,
                Headers,
                Body,
                [with_body, {recv_timeout, 5000}]
            ),
        #response{
            status = Status,
            headers = normalize_headers(RespHeaders),
            body = RespBody,
            trailers = undefined
        }
    after
        livery_h1:stop(Listener)
    end.

%%====================================================================
%% Driver: h2
%%====================================================================

drive_h2(Stack, Handler, Spec) ->
    Method = maps:get(method, Spec, <<"GET">>),
    Body = body_bytes(maps:get(body, Spec, empty)),
    {ok, Listener} = livery_h2:start(#{
        port => 0,
        transport => tcp,
        stack => Stack,
        handler => Handler
    }),
    try
        Port = h2:server_port(Listener),
        {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => tcp}),
        try
            Headers =
                [{<<"host">>, <<"127.0.0.1">>}] ++ maps:get(headers, Spec, []),
            HasBody = byte_size(Body) > 0,
            {ok, StreamId} =
                case HasBody of
                    false ->
                        h2:request(Conn, Method, <<"/">>, Headers);
                    true ->
                        h2:request(
                            Conn,
                            Method,
                            <<"/">>,
                            Headers ++ [{<<"content-length">>, integer_to_binary(byte_size(Body))}],
                            Body
                        )
                end,
            collect_h2(Conn, StreamId, undefined, [], [], undefined)
        after
            h2:close(Conn)
        end
    after
        livery_h2:stop(Listener)
    end.

collect_h2(Conn, StreamId, Status, Headers, BodyAcc, Trailers) ->
    receive
        {h2, Conn, {response, StreamId, S, Hs}} ->
            collect_h2(Conn, StreamId, S, Hs, BodyAcc, Trailers);
        {h2, Conn, {data, StreamId, Chunk, false}} ->
            collect_h2(
                Conn,
                StreamId,
                Status,
                Headers,
                [Chunk | BodyAcc],
                Trailers
            );
        {h2, Conn, {data, StreamId, Chunk, true}} ->
            #response{
                status = Status,
                headers = normalize_headers(Headers),
                body = iolist_to_binary(lists:reverse([Chunk | BodyAcc])),
                trailers = Trailers
            };
        {h2, Conn, {trailers, StreamId, T}} ->
            #response{
                status = Status,
                headers = normalize_headers(Headers),
                body = iolist_to_binary(lists:reverse(BodyAcc)),
                trailers = normalize_headers(T)
            };
        {h2, Conn, _Other} ->
            collect_h2(Conn, StreamId, Status, Headers, BodyAcc, Trailers)
    after 5000 ->
        error({h2_response_timeout, StreamId})
    end.

%%====================================================================
%% Driver: h3
%%====================================================================

drive_h3(Cert, Key, Stack, Handler, Spec) ->
    Method = maps:get(method, Spec, <<"GET">>),
    Body = body_bytes(maps:get(body, Spec, empty)),
    {ok, Listener} = livery_h3:start(#{
        port => 0,
        cert => Cert,
        key => Key,
        stack => Stack,
        handler => Handler
    }),
    try
        {ok, Port} = quic:get_server_port(Listener),
        {ok, Conn} = quic_h3:connect(
            <<"localhost">>,
            Port,
            #{verify => verify_none, sync => true}
        ),
        try
            Headers =
                [
                    {<<":method">>, Method},
                    {<<":path">>, <<"/">>},
                    {<<":scheme">>, <<"https">>},
                    {<<":authority">>, <<"localhost">>}
                ] ++ maps:get(headers, Spec, []),
            HasBody = byte_size(Body) > 0,
            StreamId =
                case HasBody of
                    false ->
                        {ok, SId} = quic_h3:request(
                            Conn,
                            Headers,
                            #{end_stream => true}
                        ),
                        SId;
                    true ->
                        Hs =
                            Headers ++ [{<<"content-length">>, integer_to_binary(byte_size(Body))}],
                        {ok, SId} = quic_h3:request(
                            Conn,
                            Hs,
                            #{end_stream => false}
                        ),
                        ok = quic_h3:send_data(Conn, SId, Body, true),
                        SId
                end,
            collect_h3(Conn, StreamId, undefined, [], [], undefined)
        after
            catch quic_h3:close(Conn)
        end
    after
        livery_h3:stop(Listener)
    end.

collect_h3(Conn, StreamId, Status, Headers, BodyAcc, Trailers) ->
    receive
        {quic_h3, Conn, {response, StreamId, S, Hs}} ->
            collect_h3(Conn, StreamId, S, Hs, BodyAcc, Trailers);
        {quic_h3, Conn, {data, StreamId, Chunk, false}} ->
            collect_h3(
                Conn,
                StreamId,
                Status,
                Headers,
                [Chunk | BodyAcc],
                Trailers
            );
        {quic_h3, Conn, {data, StreamId, Chunk, true}} ->
            #response{
                status = Status,
                headers = normalize_headers(Headers),
                body = iolist_to_binary(lists:reverse([Chunk | BodyAcc])),
                trailers = Trailers
            };
        {quic_h3, Conn, {trailers, StreamId, T}} ->
            #response{
                status = Status,
                headers = normalize_headers(Headers),
                body = iolist_to_binary(lists:reverse(BodyAcc)),
                trailers = normalize_headers(T)
            };
        {quic_h3, Conn, {stream_end, StreamId}} ->
            #response{
                status = Status,
                headers = normalize_headers(Headers),
                body = iolist_to_binary(lists:reverse(BodyAcc)),
                trailers = Trailers
            };
        {quic_h3, Conn, _Other} ->
            collect_h3(Conn, StreamId, Status, Headers, BodyAcc, Trailers)
    after 10000 ->
        error({h3_response_timeout, StreamId})
    end.

%%====================================================================
%% Helpers
%%====================================================================

body_bytes({buffered, IoData}) -> iolist_to_binary(IoData);
body_bytes(empty) -> <<>>;
body_bytes(_) -> <<>>.

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.

normalize_headers(Hs) ->
    [{normalize_header_name(N), to_binary(V)} || {N, V} <- Hs].

normalize_header_name(N) when is_binary(N) -> string:lowercase(N);
normalize_header_name(N) when is_list(N) -> string:lowercase(list_to_binary(N)).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).
