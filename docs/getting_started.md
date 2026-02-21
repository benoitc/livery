# Getting Started with Livery

Livery is a high-performance HTTP server for Erlang/OTP 27+ with support for HTTP/1.1, HTTP/2, and HTTP/3 (QUIC).

## Installation

Add Livery to your `rebar.config`:

```erlang
{deps, [
    {livery, {git, "https://github.com/benoitc/livery.git", {branch, "main"}}}
]}.
```

## Your First Handler

Create a simple handler that responds with "Hello, World!":

```erlang
-module(hello_handler).
-behaviour(livery_handler).

-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, #{opts => Opts}}.

handle(_Req, State) ->
    {reply, 200, [{<<"content-type">>, <<"text/plain">>}], <<"Hello, World!">>, State}.
```

## Starting the Server

Start Livery in your application:

```erlang
start() ->
    application:ensure_all_started(livery),
    livery:start_listener(my_http, #{
        port => 8080,
        handler => hello_handler,
        handler_opts => #{}
    }).
```

Your server is now running at `http://localhost:8080`.

## Testing with curl

```bash
# Basic request
curl http://localhost:8080
# Output: Hello, World!

# Check headers
curl -v http://localhost:8080
```

## Architecture Overview

Livery uses a straightforward architecture:

1. **Listener**: A pool of acceptor processes (default: number of schedulers)
2. **Acceptors**: Use `SO_REUSEPORT` for kernel-level load balancing
3. **Connections**: Each connection spawns a handler process
4. **Handlers**: Your callback module implementing `livery_handler` behaviour

```
Listener (Pool)
     |
     +-- Acceptor 1 (SO_REUSEPORT)
     |        |
     |        +-- Connection Handler
     |
     +-- Acceptor 2 (SO_REUSEPORT)
     |        |
     |        +-- Connection Handler
     |
     +-- Acceptor N (SO_REUSEPORT)
              |
              +-- Connection Handler
```

**Key Points:**
- Each acceptor listens on the same port using `SO_REUSEPORT`
- The kernel distributes connections across acceptors
- No single-process bottleneck

## What's Next

- [Handlers](handlers.md) - Learn about the handler behaviour and callbacks
- [Request/Response](request_response.md) - Request API and response patterns
- [Routing](routing.md) - Setting up routes for your API
- [REST API Guide](rest_api.md) - Building a complete REST API
- [WebSocket Guide](websocket.md) - Real-time communication with WebSockets
