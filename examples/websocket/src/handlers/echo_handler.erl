-module(echo_handler).
-behaviour(livery_handler).

-export([init/2, handle/2, websocket_handle/2, websocket_info/2]).

init(Req, Opts) ->
    case livery_req:is_websocket_upgrade(Req) of
        true ->
            io:format("Echo WebSocket connection accepted~n"),
            {websocket, Req, #{connected_at => erlang:system_time(second)}};
        false ->
            {ok, Req, Opts}
    end.

handle(_Req, State) ->
    Html = <<"<!DOCTYPE html>
<html>
<head><title>WebSocket Echo</title></head>
<body>
<h1>WebSocket Echo Server</h1>
<p>Connect using: <code>ws://localhost:8080/echo</code></p>
<p>Or use websocat: <code>websocat ws://localhost:8080/echo</code></p>
</body>
</html>">>,
    livery_helpers:reply_html(200, Html, State).

websocket_handle({text, Text}, State) ->
    io:format("Echo received: ~s~n", [Text]),
    Reply = <<"Echo: ", Text/binary>>,
    {reply, {text, Reply}, State};

websocket_handle({binary, Data}, State) ->
    io:format("Echo received binary: ~p bytes~n", [byte_size(Data)]),
    {reply, {binary, Data}, State};

websocket_handle({ping, Payload}, State) ->
    {reply, {pong, Payload}, State};

websocket_handle({close, Code, Reason}, State) ->
    io:format("Echo WebSocket closed: ~p ~p~n", [Code, Reason]),
    {stop, normal, State}.

websocket_info(_Info, State) ->
    {ok, State}.
