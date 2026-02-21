# WebSocket

Livery supports WebSocket over HTTP/1.1, HTTP/2, and HTTP/3 (RFC 9220).

## Basic WebSocket Handler

```erlang
-module(ws_handler).
-behaviour(livery_handler).

-export([init/2, handle/2, websocket_handle/2, websocket_info/2]).

%% Accept WebSocket upgrade
init(Req, Opts) ->
    case livery_req:is_websocket_upgrade(Req) of
        true ->
            {websocket, Req, #{opts => Opts}};
        false ->
            {ok, Req, #{opts => Opts}}
    end.

%% Handle regular HTTP (if not upgraded)
handle(_Req, State) ->
    {reply, 400, [], <<"WebSocket upgrade required">>, State}.

%% Handle incoming WebSocket frames
websocket_handle({text, Text}, State) ->
    %% Echo text messages
    {reply, {text, Text}, State};

websocket_handle({binary, Data}, State) ->
    %% Echo binary data
    {reply, {binary, Data}, State};

websocket_handle({ping, Payload}, State) ->
    %% Respond to ping with pong
    {reply, {pong, Payload}, State};

websocket_handle({close, Code, Reason}, State) ->
    %% Client initiated close
    io:format("WebSocket closed: ~p ~p~n", [Code, Reason]),
    {stop, normal, State}.

%% Handle Erlang messages (e.g., from other processes)
websocket_info({broadcast, Message}, State) ->
    {reply, {text, Message}, State};

websocket_info(_Info, State) ->
    {ok, State}.
```

## Frame Types

### Incoming Frames (from client)

```erlang
{text, Binary}           %% UTF-8 text
{binary, Binary}         %% Binary data
{ping, Payload}          %% Ping frame
{pong, Payload}          %% Pong frame (usually ignored)
{close, Code, Reason}    %% Close frame
```

### Outgoing Frames (to client)

```erlang
{text, Binary}           %% Send text
{binary, Binary}         %% Send binary
{ping, Payload}          %% Send ping
{pong, Payload}          %% Send pong
{close, Code, Reason}    %% Initiate close
```

## Return Values

```erlang
{ok, State}              %% Continue without sending
{reply, Frame, State}    %% Send frame and continue
{stop, Reason, State}    %% Close connection
```

## Echo Server Example

A complete echo server that handles all message types:

```erlang
-module(echo_handler).
-behaviour(livery_handler).

-export([init/2, handle/2, websocket_handle/2, websocket_info/2]).

init(Req, Opts) ->
    case livery_req:is_websocket_upgrade(Req) of
        true ->
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
<p>Connect to ws://localhost:8080/ws</p>
</body>
</html>">>,
    livery_helpers:reply_html(200, Html, State).

websocket_handle({text, Text}, State) ->
    %% Echo with prefix
    Reply = <<"Echo: ", Text/binary>>,
    {reply, {text, Reply}, State};

websocket_handle({binary, Data}, State) ->
    {reply, {binary, Data}, State};

websocket_handle({ping, Payload}, State) ->
    {reply, {pong, Payload}, State};

websocket_handle({close, _, _}, State) ->
    {stop, normal, State}.

websocket_info(_, State) ->
    {ok, State}.
```

## Chat Server Example

A WebSocket-based chat server with multiple clients:

```erlang
-module(chat_handler).
-behaviour(livery_handler).

-export([init/2, handle/2, websocket_handle/2, websocket_info/2, terminate/2]).

init(Req, Opts) ->
    case livery_req:is_websocket_upgrade(Req) of
        true ->
            %% Get username from query string
            Username = livery_helpers:get_qs_value(<<"username">>, Req, <<"anonymous">>),
            %% Join the chat room
            pg:join(chat_room, self()),
            {websocket, Req, #{username => Username}};
        false ->
            {ok, Req, Opts}
    end.

handle(_Req, State) ->
    livery_helpers:reply_html(200, chat_page(), State).

websocket_handle({text, Message}, #{username := Username} = State) ->
    %% Broadcast to all connected clients
    Payload = json:encode(#{
        type => <<"message">>,
        username => Username,
        text => Message,
        timestamp => erlang:system_time(millisecond)
    }),

    %% Send to all members except self
    Members = pg:get_members(chat_room) -- [self()],
    lists:foreach(fun(Pid) ->
        Pid ! {chat_message, Payload}
    end, Members),

    %% Confirm to sender
    {reply, {text, Payload}, State};

websocket_handle({close, _, _}, State) ->
    {stop, normal, State}.

websocket_info({chat_message, Payload}, State) ->
    {reply, {text, Payload}, State};

websocket_info(_, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    pg:leave(chat_room, self()),
    ok.

chat_page() ->
    <<"<!DOCTYPE html>
<html>
<head><title>Chat</title></head>
<body>
<h1>Chat Room</h1>
<div id=\"messages\"></div>
<input id=\"input\" type=\"text\" placeholder=\"Type a message...\">
<button onclick=\"send()\">Send</button>
<script>
const username = prompt('Enter your username:', 'user');
const ws = new WebSocket('ws://localhost:8080/chat?username=' + username);
ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    document.getElementById('messages').innerHTML +=
        '<p><b>' + msg.username + ':</b> ' + msg.text + '</p>';
};
function send() {
    ws.send(document.getElementById('input').value);
    document.getElementById('input').value = '';
}
</script>
</body>
</html>">>.
```

## Server Setup

```erlang
start() ->
    application:ensure_all_started(livery),

    Routes = [
        {get, "/ws", echo_handler, #{}},
        {get, "/chat", chat_handler, #{}}
    ],
    Router = livery_router:compile(Routes),

    livery:start_listener(ws_server, #{
        port => 8080,
        handler => livery_routing_handler,
        handler_opts => #{router => Router}
    }).
```

## Docker Setup

### Dockerfile

```dockerfile
FROM erlang:27-alpine

WORKDIR /app

COPY rebar.config rebar.lock ./
RUN rebar3 compile || true

COPY . .
RUN rebar3 release

EXPOSE 8080

CMD ["_build/default/rel/ws_example/bin/ws_example", "foreground"]
```

### docker-compose.yml

```yaml
version: '3.8'
services:
  ws_example:
    build: .
    ports:
      - "8080:8080"
```

## Testing WebSocket

### Using websocat

```bash
# Install websocat
# macOS: brew install websocat
# Linux: cargo install websocat

# Connect to echo server
websocat ws://localhost:8080/ws

# Type messages and see echoes

# Connect to chat with username
websocat "ws://localhost:8080/chat?username=alice"
```

### Using curl (HTTP/1.1 Upgrade)

```bash
# Initiate WebSocket upgrade
curl --include \
  --no-buffer \
  --header "Connection: Upgrade" \
  --header "Upgrade: websocket" \
  --header "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
  --header "Sec-WebSocket-Version: 13" \
  http://localhost:8080/ws
```

### JavaScript Client

```javascript
const ws = new WebSocket('ws://localhost:8080/ws');

ws.onopen = () => {
    console.log('Connected');
    ws.send('Hello, server!');
};

ws.onmessage = (event) => {
    console.log('Received:', event.data);
};

ws.onclose = () => {
    console.log('Disconnected');
};

ws.onerror = (error) => {
    console.error('WebSocket error:', error);
};
```

## The livery_ws Module

The `livery_ws` module provides low-level WebSocket frame operations:

```erlang
%% Check if request is WebSocket upgrade
livery_ws:is_upgrade_request(Headers)

%% Calculate Sec-WebSocket-Accept key
AcceptKey = livery_ws:upgrade_key(ClientKey)

%% Build handshake response headers
Headers = livery_ws:handshake_response(ClientKey)

%% Encode frames
Binary = livery_ws:encode_text(<<"Hello">>)
Binary = livery_ws:encode_binary(Data)
Binary = livery_ws:encode_ping(Payload)
Binary = livery_ws:encode_pong(Payload)
Binary = livery_ws:encode_close()
Binary = livery_ws:encode_close(1000)
Binary = livery_ws:encode_close(1000, <<"Goodbye">>)

%% Decode frames
{ok, Opcode, Payload, Fin, Rest} = livery_ws:decode_frame(Data)
{more, N} = livery_ws:decode_frame(PartialData)  % Need N more bytes
```
