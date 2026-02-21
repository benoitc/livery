-module(index_handler).
-behaviour(livery_handler).

-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(_Req, State) ->
    Html = <<"<!DOCTYPE html>
<html>
<head>
    <title>Livery WebSocket Examples</title>
    <style>
        body { font-family: sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; }
        h1 { color: #333; }
        h2 { color: #666; margin-top: 30px; }
        .example { background: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0; }
        input, button { padding: 10px; margin: 5px 0; }
        input { width: 300px; }
        button { background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }
        button:hover { background: #0056b3; }
        #echo-messages, #chat-messages {
            height: 200px;
            overflow-y: auto;
            border: 1px solid #ddd;
            padding: 10px;
            background: white;
            margin: 10px 0;
        }
        .message { margin: 5px 0; padding: 5px; background: #e9ecef; border-radius: 4px; }
        .system { color: #666; font-style: italic; }
    </style>
</head>
<body>
    <h1>Livery WebSocket Examples</h1>

    <div class=\"example\">
        <h2>Echo Server</h2>
        <p>Messages are echoed back with a prefix.</p>
        <div id=\"echo-messages\"></div>
        <input type=\"text\" id=\"echo-input\" placeholder=\"Type a message...\">
        <button onclick=\"sendEcho()\">Send</button>
        <button onclick=\"connectEcho()\">Connect</button>
        <button onclick=\"disconnectEcho()\">Disconnect</button>
    </div>

    <div class=\"example\">
        <h2>Chat Room</h2>
        <p>Messages are broadcast to all connected clients.</p>
        <input type=\"text\" id=\"username\" placeholder=\"Your username\" value=\"user\">
        <div id=\"chat-messages\"></div>
        <input type=\"text\" id=\"chat-input\" placeholder=\"Type a message...\">
        <button onclick=\"sendChat()\">Send</button>
        <button onclick=\"connectChat()\">Connect</button>
        <button onclick=\"disconnectChat()\">Disconnect</button>
    </div>

    <script>
        let echoWs = null;
        let chatWs = null;

        function addEchoMessage(text, isSystem) {
            const div = document.createElement('div');
            div.className = isSystem ? 'message system' : 'message';
            div.textContent = text;
            document.getElementById('echo-messages').appendChild(div);
            div.scrollIntoView();
        }

        function addChatMessage(text, isSystem) {
            const div = document.createElement('div');
            div.className = isSystem ? 'message system' : 'message';
            div.textContent = text;
            document.getElementById('chat-messages').appendChild(div);
            div.scrollIntoView();
        }

        function connectEcho() {
            if (echoWs) echoWs.close();
            echoWs = new WebSocket('ws://localhost:8080/echo');
            echoWs.onopen = () => addEchoMessage('Connected to echo server', true);
            echoWs.onmessage = (e) => addEchoMessage(e.data, false);
            echoWs.onclose = () => addEchoMessage('Disconnected', true);
            echoWs.onerror = (e) => addEchoMessage('Error: ' + e, true);
        }

        function disconnectEcho() {
            if (echoWs) echoWs.close();
        }

        function sendEcho() {
            const input = document.getElementById('echo-input');
            if (echoWs && echoWs.readyState === WebSocket.OPEN) {
                echoWs.send(input.value);
                input.value = '';
            } else {
                addEchoMessage('Not connected', true);
            }
        }

        function connectChat() {
            if (chatWs) chatWs.close();
            const username = document.getElementById('username').value || 'anonymous';
            chatWs = new WebSocket('ws://localhost:8080/chat?username=' + encodeURIComponent(username));
            chatWs.onopen = () => addChatMessage('Connected as ' + username, true);
            chatWs.onmessage = (e) => {
                try {
                    const msg = JSON.parse(e.data);
                    addChatMessage(msg.username + ': ' + msg.text, false);
                } catch (err) {
                    addChatMessage(e.data, false);
                }
            };
            chatWs.onclose = () => addChatMessage('Disconnected', true);
            chatWs.onerror = (e) => addChatMessage('Error: ' + e, true);
        }

        function disconnectChat() {
            if (chatWs) chatWs.close();
        }

        function sendChat() {
            const input = document.getElementById('chat-input');
            if (chatWs && chatWs.readyState === WebSocket.OPEN) {
                chatWs.send(input.value);
                input.value = '';
            } else {
                addChatMessage('Not connected', true);
            }
        }

        // Handle Enter key
        document.getElementById('echo-input').addEventListener('keypress', (e) => {
            if (e.key === 'Enter') sendEcho();
        });
        document.getElementById('chat-input').addEventListener('keypress', (e) => {
            if (e.key === 'Enter') sendChat();
        });
    </script>
</body>
</html>">>,
    livery_helpers:reply_html(200, Html, State).
