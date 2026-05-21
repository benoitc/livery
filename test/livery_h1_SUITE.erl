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
    streaming_chunked_response/1,
    sse_response/1,
    echo_buffered_body/1,
    error_500_on_crash/1
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
        streaming_chunked_response,
        sse_response,
        echo_buffered_body,
        error_500_on_crash
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
        handler => Handler
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

error_500_on_crash(Config) ->
    {ok, Status, _Headers, Body} = get(Config, <<"/">>),
    ?assertEqual(500, Status),
    ?assertEqual(<<"internal server error">>, Body).

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
handler_for(binding_via_routed_handler) ->
    fun(R) ->
        case livery_req:path(R) of
            <<"/hi/", Name/binary>> ->
                livery_resp:text(200, [<<"hello, ">>, Name]);
            _ ->
                livery_resp:text(404, <<>>)
        end
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
handler_for(error_500_on_crash) ->
    fun(_R) -> error(boom) end.

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

normalize(Headers) ->
    [{string:lowercase(N), V} || {N, V} <- Headers].

header(Name, Headers) ->
    LName = string:lowercase(Name),
    case lists:keyfind(LName, 1, Headers) of
        {_, V} when is_binary(V) -> V;
        {_, V} when is_list(V) -> list_to_binary(V);
        false -> undefined
    end.
