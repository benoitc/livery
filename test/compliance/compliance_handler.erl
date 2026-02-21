%% @doc Echo handler for HTTP compliance testing.
%%
%% Provides simple endpoints for testing HTTP/1.1 and HTTP/2 compliance:
%% - / : Hello World
%% - /echo : Echo request body
%% - /headers : Echo request headers
%% - /stream : Chunked streaming response
%% - /status/:code : Return specific status code
-module(compliance_handler).

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

%% Root - Hello World
handle_route(<<"GET">>, <<"/">>, _Req, State) ->
    {reply, 200, [{<<"content-type">>, <<"text/plain">>}], <<"Hello, World!">>, State};

%% Echo body
handle_route(<<"POST">>, <<"/echo">>, Req, State) ->
    Body = case livery_req:body(Req) of
        undefined -> <<>>;
        B -> B
    end,
    ContentType = livery_req:header(<<"content-type">>, Req, <<"text/plain">>),
    BodyLen = integer_to_binary(byte_size(Body)),
    Headers = [
        {<<"content-type">>, ContentType},
        {<<"x-body-length">>, BodyLen}
    ],
    {reply, 200, Headers, Body, State};

%% Echo headers
handle_route(<<"GET">>, <<"/headers">>, Req, State) ->
    Headers = livery_req:headers(Req),
    Body = iolist_to_binary([
        [Name, <<": ">>, Value, <<"\n">>]
        || {Name, Value} <- Headers
    ]),
    {reply, 200, [{<<"content-type">>, <<"text/plain">>}], Body, State};

%% Streaming response
handle_route(<<"GET">>, <<"/stream">>, _Req, State) ->
    StreamFun = fun(Send) ->
        Send(<<"chunk1">>),
        Send(<<"chunk2">>),
        Send(<<"chunk3">>),
        Send(done)
    end,
    {stream, 200, [{<<"content-type">>, <<"text/plain">>}], StreamFun, State};

%% Streaming with trailers
handle_route(<<"GET">>, <<"/stream-with-trailers">>, _Req, State) ->
    StreamFun = fun(Send) ->
        Send(<<"data">>),
        Send({done, [{<<"x-checksum">>, <<"abc123">>}]})
    end,
    {stream, 200, [{<<"content-type">>, <<"text/plain">>}], StreamFun, State};

%% Return specific status code
handle_route(<<"GET">>, <<"/status/", StatusBin/binary>>, _Req, State) ->
    Status = binary_to_integer(StatusBin),
    {reply, Status, [{<<"content-type">>, <<"text/plain">>}], livery_resp:status_text(Status), State};

%% JSON response
handle_route(<<"GET">>, <<"/json">>, _Req, State) ->
    Body = <<"{\"message\":\"hello\",\"protocol\":\"http\"}">>,
    {reply, 200, [{<<"content-type">>, <<"application/json">>}], Body, State};

%% Large response for testing flow control
handle_route(<<"GET">>, <<"/large">>, _Req, State) ->
    %% 1MB of data
    Body = binary:copy(<<"X">>, 1024 * 1024),
    {reply, 200, [{<<"content-type">>, <<"application/octet-stream">>}], Body, State};

%% Slow response for timeout testing
handle_route(<<"GET">>, <<"/slow">>, _Req, State) ->
    timer:sleep(100),
    {reply, 200, [{<<"content-type">>, <<"text/plain">>}], <<"done">>, State};

%% Query string echo
handle_route(<<"GET">>, <<"/query">>, Req, State) ->
    Qs = livery_req:qs(Req),
    {reply, 200, [{<<"content-type">>, <<"text/plain">>}], Qs, State};

%% Not found
handle_route(_, _, _Req, State) ->
    {reply, 404, [{<<"content-type">>, <<"text/plain">>}], <<"Not Found">>, State}.
