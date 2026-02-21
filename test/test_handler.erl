%% @doc Test handler for E2E tests.
-module(test_handler).

-behaviour(livery_handler).

-export([init/2, handle/2, terminate/2]).

-include_lib("livery/include/livery.hrl").

init(Req, Opts) ->
    {ok, Req, #{opts => Opts}}.

handle(Req, State) ->
    Method = livery_req:method(Req),
    Path = livery_req:path(Req),
    handle_route(Method, Path, Req, State).

terminate(_Reason, _State) ->
    ok.

%% Routes

handle_route(<<"GET">>, <<"/">>, _Req, State) ->
    {reply, 200, [{<<"content-type">>, <<"text/plain">>}], <<"Hello, World!">>, State};

handle_route(<<"GET">>, <<"/json">>, _Req, State) ->
    Body = <<"{\"message\":\"hello\"}">>,
    {reply, 200, [{<<"content-type">>, <<"application/json">>}], Body, State};

handle_route(<<"POST">>, <<"/echo">>, Req, State) ->
    Body = case livery_req:body(Req) of
        undefined -> <<>>;
        B -> B
    end,
    ContentType = livery_req:header(<<"content-type">>, Req, <<"text/plain">>),
    {reply, 200, [{<<"content-type">>, ContentType}], Body, State};

handle_route(<<"GET">>, <<"/headers">>, Req, State) ->
    Headers = livery_req:headers(Req),
    Body = iolist_to_binary([
        [Name, <<": ">>, Value, <<"\n">>]
        || {Name, Value} <- Headers
    ]),
    {reply, 200, [{<<"content-type">>, <<"text/plain">>}], Body, State};

handle_route(<<"GET">>, <<"/slow">>, _Req, State) ->
    timer:sleep(100),
    {reply, 200, [{<<"content-type">>, <<"text/plain">>}], <<"done">>, State};

handle_route(<<"GET">>, <<"/status/", StatusBin/binary>>, _Req, State) ->
    Status = binary_to_integer(StatusBin),
    {reply, Status, [{<<"content-type">>, <<"text/plain">>}], livery_resp:status_text(Status), State};

handle_route(<<"GET">>, <<"/query">>, Req, State) ->
    Qs = livery_req:qs(Req),
    {reply, 200, [{<<"content-type">>, <<"text/plain">>}], Qs, State};

%% Chunked request body - echoes the body back
handle_route(<<"POST">>, <<"/chunked-echo">>, Req, State) ->
    Body = case livery_req:body(Req) of
        undefined -> <<>>;
        B -> B
    end,
    ContentType = livery_req:header(<<"content-type">>, Req, <<"text/plain">>),
    %% Also return the body length to verify chunked decoding
    BodyLen = integer_to_binary(byte_size(Body)),
    Headers = [{<<"content-type">>, ContentType}, {<<"x-body-length">>, BodyLen}],
    {reply, 200, Headers, Body, State};

%% Streaming response - sends 3 chunks
handle_route(<<"GET">>, <<"/stream">>, _Req, State) ->
    StreamFun = fun(Send) ->
        Send(<<"chunk1">>),
        Send(<<"chunk2">>),
        Send(<<"chunk3">>),
        Send(done)
    end,
    {stream, 200, [{<<"content-type">>, <<"text/plain">>}], StreamFun, State};

%% Streaming response with trailers
handle_route(<<"GET">>, <<"/stream-with-trailers">>, _Req, State) ->
    StreamFun = fun(Send) ->
        Send(<<"data">>),
        Send({done, [{<<"x-checksum">>, <<"abc123">>}]})
    end,
    {stream, 200, [{<<"content-type">>, <<"text/plain">>}], StreamFun, State};

handle_route(_, _, _Req, State) ->
    {reply, 404, [{<<"content-type">>, <<"text/plain">>}], <<"Not Found">>, State}.
