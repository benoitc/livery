-module(chat_handler).
-behaviour(livery_handler).

-export([init/2, handle/2, websocket_handle/2, websocket_info/2, terminate/2]).

init(Req, Opts) ->
    case livery_req:is_websocket_upgrade(Req) of
        true ->
            %% Get username from query string
            Username = livery_helpers:get_qs_value(<<"username">>, Req, <<"anonymous">>),
            io:format("Chat: ~s joined~n", [Username]),

            %% Join the chat room
            pg:join(chat, chat_room, self()),

            %% Notify others
            broadcast(#{
                type => <<"system">>,
                text => <<Username/binary, " joined the chat">>,
                timestamp => erlang:system_time(millisecond)
            }),

            {websocket, Req, #{username => Username}};
        false ->
            {ok, Req, Opts}
    end.

handle(_Req, State) ->
    Html = <<"<!DOCTYPE html>
<html>
<head><title>WebSocket Chat</title></head>
<body>
<h1>WebSocket Chat Server</h1>
<p>Connect using: <code>ws://localhost:8080/chat?username=yourname</code></p>
<p>Or use websocat: <code>websocat 'ws://localhost:8080/chat?username=alice'</code></p>
</body>
</html>">>,
    livery_helpers:reply_html(200, Html, State).

websocket_handle({text, Message}, #{username := Username} = State) ->
    io:format("Chat: ~s says: ~s~n", [Username, Message]),

    %% Broadcast to all connected clients (including self)
    Payload = #{
        type => <<"message">>,
        username => Username,
        text => Message,
        timestamp => erlang:system_time(millisecond)
    },
    broadcast(Payload),

    {ok, State};

websocket_handle({ping, Payload}, State) ->
    {reply, {pong, Payload}, State};

websocket_handle({close, _, _}, State) ->
    {stop, normal, State}.

websocket_info({chat_message, Payload}, State) ->
    {reply, {text, Payload}, State};

websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, #{username := Username}) ->
    io:format("Chat: ~s left~n", [Username]),

    %% Leave the chat room
    pg:leave(chat, chat_room, self()),

    %% Notify others
    broadcast(#{
        type => <<"system">>,
        text => <<Username/binary, " left the chat">>,
        timestamp => erlang:system_time(millisecond)
    }),
    ok;
terminate(_Reason, _State) ->
    ok.

broadcast(Payload) ->
    PayloadBin = json:encode(Payload),
    Members = pg:get_members(chat, chat_room),
    lists:foreach(fun(Pid) ->
        Pid ! {chat_message, PayloadBin}
    end, Members).
