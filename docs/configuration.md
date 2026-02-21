# Configuration

This guide covers server configuration options, HTTPS setup, HTTP/2 and HTTP/3, and graceful shutdown.

## Starting Listeners

### Basic HTTP Server

```erlang
livery:start_listener(my_http, #{
    port => 8080,
    handler => my_handler,
    handler_opts => #{}
}).
```

### With Custom Options

```erlang
livery:start_listener(my_http, #{
    port => 8080,
    handler => my_handler,
    handler_opts => #{db_pool => my_db},

    %% Number of acceptor processes
    num_acceptors => erlang:system_info(schedulers),

    %% TCP options
    tcp_opts => [
        {backlog, 1024},
        {nodelay, true}
    ]
}).
```

## Listener Options Reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `port` | integer | required | TCP port to listen on |
| `handler` | module | required | Handler module |
| `handler_opts` | term | `#{}` | Options passed to handler |
| `num_acceptors` | integer \| auto | auto | Number of acceptor processes |
| `ssl_opts` | list | `[]` | SSL options for HTTPS |
| `tcp_opts` | list | `[]` | TCP socket options |

## TCP Options

Common TCP options:

```erlang
tcp_opts => [
    {backlog, 1024},      %% Connection backlog
    {nodelay, true},      %% Disable Nagle's algorithm
    {sndbuf, 65536},      %% Send buffer size
    {recbuf, 65536},      %% Receive buffer size
    {keepalive, true}     %% Enable keepalive
]
```

## HTTPS Configuration

```erlang
livery:start_listener(my_https, #{
    port => 8443,
    handler => my_handler,
    ssl_opts => [
        {certfile, "/path/to/fullchain.pem"},
        {keyfile, "/path/to/privkey.pem"},
        {cacertfile, "/path/to/chain.pem"},

        %% TLS versions
        {versions, ['tlsv1.3', 'tlsv1.2']},

        %% Cipher suites (TLS 1.3)
        {ciphers, [
            "TLS_AES_256_GCM_SHA384",
            "TLS_CHACHA20_POLY1305_SHA256",
            "TLS_AES_128_GCM_SHA256"
        ]},

        %% ALPN for HTTP/2
        {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}
    ]
}).
```

### Self-Signed Certificates (Development)

```bash
# Generate self-signed certificate
openssl req -x509 -newkey rsa:4096 \
    -keyout key.pem -out cert.pem \
    -days 365 -nodes \
    -subj "/CN=localhost"
```

```erlang
livery:start_listener(dev_https, #{
    port => 8443,
    handler => my_handler,
    ssl_opts => [
        {certfile, "cert.pem"},
        {keyfile, "key.pem"}
    ]
}).
```

## HTTP/2 Configuration

HTTP/2 is automatically negotiated via ALPN when using HTTPS:

```erlang
livery:start_listener(my_h2, #{
    port => 8443,
    handler => my_handler,
    ssl_opts => [
        {certfile, "cert.pem"},
        {keyfile, "key.pem"},
        %% Enable HTTP/2
        {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}
    ]
}).
```

## HTTP/3 (QUIC) Configuration

HTTP/3 uses QUIC transport over UDP:

```erlang
%% Read certificates (DER format required)
{ok, CertDer} = file:read_file("cert.der"),
{ok, KeyDer} = file:read_file("key.der"),

livery:start_h3_listener(my_h3, #{
    port => 8443,
    handler => my_handler,
    cert => CertDer,
    key => KeyDer,
    pool_size => erlang:system_info(schedulers)
}).
```

### Converting PEM to DER

```bash
# Convert certificate
openssl x509 -in cert.pem -outform DER -out cert.der

# Convert private key
openssl rsa -in key.pem -outform DER -out key.der
```

## Multiple Listeners

```erlang
%% HTTP on port 80
livery:start_listener(http_80, #{port => 80, handler => my_handler}),

%% HTTPS on port 443
livery:start_listener(https_443, #{
    port => 443,
    handler => my_handler,
    ssl_opts => [
        {certfile, "cert.pem"},
        {keyfile, "key.pem"}
    ]
}),

%% Internal API on different port
livery:start_listener(internal_api, #{
    port => 9090,
    handler => internal_handler
}).
```

## Stopping Listeners

```erlang
%% Stop a listener
livery:stop_listener(my_http).

%% Stop HTTP/3 listener
livery:stop_h3_listener(my_h3).
```

## Graceful Shutdown

The `livery_shutdown` module provides graceful shutdown:

```erlang
%% Graceful shutdown with 30 second timeout
livery_shutdown:graceful(my_http, 30000).

%% Immediate shutdown
livery_shutdown:immediate(my_http).

%% Shutdown all listeners
livery_shutdown:shutdown_all(30000).
```

Graceful shutdown:
1. Stops accepting new connections
2. Allows in-flight requests to complete
3. Sends appropriate protocol-level signals (GOAWAY for HTTP/2/3)
4. Enforces the timeout

### Integration with Application Stop

```erlang
-module(my_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, _} = livery:start_listener(my_http, #{
        port => 8080,
        handler => my_handler
    }),
    my_sup:start_link().

stop(_State) ->
    %% Graceful shutdown with 30 second timeout
    livery_shutdown:graceful(my_http, 30000),
    ok.
```

## Server Information

The `livery_info` module provides runtime information:

```erlang
%% Get overall server info
Info = livery_info:info().
%% #{version => <<"1.0.0">>,
%%   otp_version => <<"27">>,
%%   listeners => [my_http],
%%   total_connections => 42,
%%   ...}

%% Get server version
Version = livery_info:version().

%% Get listener-specific info
ListenerInfo = livery_info:listener_info(my_http).
%% #{name => my_http, acceptors => 8, connections => 10, status => running}

%% Get info for all listeners
AllInfo = livery_info:all_listener_info().

%% Get connection counts
Count = livery_info:connection_count(my_http).
Total = livery_info:total_connections().

%% List supported protocols
Protocols = livery_info:supported_protocols().
%% [http1, http2, http3, websocket]
```

## Listing Listeners

```erlang
%% List HTTP/HTTPS listeners
Listeners = livery:which_listeners().
%% [my_http, my_https]

%% List HTTP/3 listeners
H3Listeners = livery:which_h3_listeners().
%% [my_h3]
```

## Request Limits

Default limits (defined in `livery.hrl`):

| Limit | Default | Description |
|-------|---------|-------------|
| `MAX_METHOD_SIZE` | 16 | Max HTTP method length |
| `MAX_URI_SIZE` | 8192 | Max URI length |
| `MAX_HEADER_NAME_SIZE` | 256 | Max header name length |
| `MAX_HEADER_VALUE_SIZE` | 8192 | Max header value length |
| `MAX_HEADERS` | 100 | Max number of headers |
| `MAX_CHUNK_SIZE` | 1MB | Max chunked encoding chunk |
| `MAX_BODY_SIZE` | 8MB | Max request body size |

## Environment Variables

Configure via application environment:

```erlang
%% In sys.config
[
    {livery, [
        {default_port, 8080},
        {max_body_size, 10485760}  % 10MB
    ]}
].
```

Access in code:

```erlang
Port = application:get_env(livery, default_port, 8080).
```
