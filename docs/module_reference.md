# Module Reference

Quick reference for all public modules in Livery.

## livery

Main API for starting and managing HTTP servers.

```erlang
%% Start HTTP/HTTPS listener
{ok, Pid} = livery:start_listener(Name, Opts).

%% Stop listener
ok = livery:stop_listener(Name).

%% List listeners
[Name] = livery:which_listeners().

%% Start HTTP/3 (QUIC) listener
{ok, Pid} = livery:start_h3_listener(Name, Opts).

%% Stop HTTP/3 listener
ok = livery:stop_h3_listener(Name).

%% List HTTP/3 listeners
[Name] = livery:which_h3_listeners().
```

**Listener Options:**
- `port` (required) - TCP/UDP port
- `handler` (required) - Handler module
- `handler_opts` - Options passed to handler
- `num_acceptors` - Acceptor process count (default: auto)
- `ssl_opts` - SSL/TLS options for HTTPS

**HTTP/3 Options:**
- `port` (required) - UDP port
- `handler` (required) - Handler module
- `cert` (required) - DER-encoded certificate
- `key` (required) - DER-encoded private key
- `pool_size` - Listener process count

## livery_handler

Behaviour for HTTP handlers.

**Callbacks:**

```erlang
-callback init(Req, Opts) ->
    {ok, Req, State} |
    {websocket, Req, State} |
    {error, Reason}.

-callback handle(Req, State) ->
    {reply, Status, Headers, Body, State} |
    {reply, Status, Headers, State} |
    {stream, Status, Headers, StreamFun, State} |
    {error, Reason, State}.

-callback terminate(Reason, State) -> ok.  % optional

-callback websocket_handle(Frame, State) ->
    {ok, State} |
    {reply, Frame, State} |
    {stop, Reason, State}.  % optional

-callback websocket_info(Info, State) ->
    {ok, State} |
    {reply, Frame, State} |
    {stop, Reason, State}.  % optional
```

## livery_req

Request accessors.

```erlang
%% Basic accessors
Method = livery_req:method(Req).           % <<"GET">>
Path = livery_req:path(Req).               % <<"/users/123">>
QS = livery_req:qs(Req).                   % <<"page=1">>
Version = livery_req:version(Req).         % {1, 1}
Headers = livery_req:headers(Req).         % [{Name, Value}]
Header = livery_req:header(Name, Req).     % binary() | undefined
Header = livery_req:header(Name, Req, Default).
Body = livery_req:body(Req).               % binary() | undefined
HasBody = livery_req:has_body(Req).        % boolean()
Length = livery_req:body_length(Req).      % integer | chunked | undefined
{IP, Port} = livery_req:peer(Req).

%% Convenience accessors
Scheme = livery_req:scheme(Req).           % http | https
Host = livery_req:host(Req).               % <<"example.com">>
Port = livery_req:port(Req).               % 8080
CT = livery_req:content_type(Req).         % <<"application/json">>
Len = livery_req:content_length(Req).      % integer | undefined
Accept = livery_req:accept(Req).           % binary() | undefined
UA = livery_req:user_agent(Req).           % binary() | undefined
IsWS = livery_req:is_websocket_upgrade(Req).  % boolean()
IsSSL = livery_req:is_ssl(Req).            % boolean()
```

## livery_helpers

Convenience functions for handlers.

```erlang
%% Query string
QS = livery_helpers:parse_qs(Req).                    % #{Key => Value}
Value = livery_helpers:get_qs_value(Key, Req).        % binary() | undefined
Value = livery_helpers:get_qs_value(Key, Req, Default).

%% Form parsing
Form = livery_helpers:parse_form(Req).                % #{Key => Value}
{ok, Parts} = livery_helpers:parse_multipart(Req).    % [#{name, data, ...}]

%% JSON
{ok, Data} = livery_helpers:json_body(Req).
{reply, ...} = livery_helpers:reply_json(Status, Data, State).
{reply, ...} = livery_helpers:reply_json(Status, Data, Headers, State).

%% Response helpers
{reply, ...} = livery_helpers:reply_text(Status, Text, State).
{reply, ...} = livery_helpers:reply_html(Status, Html, State).
{reply, ...} = livery_helpers:reply_file(Status, Path, State).
{reply, ...} = livery_helpers:reply_redirect(Location, State).
{reply, ...} = livery_helpers:reply_redirect(Status, Location, State).
{reply, ...} = livery_helpers:reply_not_found(State).
{reply, ...} = livery_helpers:reply_bad_request(Message, State).
{reply, ...} = livery_helpers:reply_internal_error(Message, State).

%% Cookies
Value = livery_helpers:get_cookie(Name, Req).
Value = livery_helpers:get_cookie(Name, Req, Default).
{HeaderName, HeaderValue} = livery_helpers:set_cookie(Name, Value, Opts).
{HeaderName, HeaderValue} = livery_helpers:delete_cookie(Name).

%% Path bindings (when using router)
Value = livery_helpers:binding(Name, Opts).
Value = livery_helpers:binding(Name, Opts, Default).
Bindings = livery_helpers:bindings(Opts).             % #{Name => Value}

%% Content negotiation
true = livery_helpers:accepts(ContentType, Req).
true = livery_helpers:accepts_json(Req).
true = livery_helpers:accepts_html(Req).
Type = livery_helpers:preferred_type([Type1, Type2], Req).
```

## livery_resp

Response building (low-level).

```erlang
%% Build response
IOData = livery_resp:build(Status, Headers, Body, {1, 1}).
IOData = livery_resp:build(Status, Headers, {1, 1}).

%% Status text
Text = livery_resp:status_text(404).  % <<"Not Found">>

%% Chunked encoding
IOData = livery_resp:build_chunked_start(Status, Headers, {1, 1}).
IOData = livery_resp:encode_chunk(Data).
Binary = livery_resp:encode_last_chunk().
IOData = livery_resp:encode_last_chunk(Trailers).
```

## livery_router

HTTP router with prefix tree matching.

```erlang
%% Compile routes
Router = livery_router:compile([
    {get, "/", handler, #{}},
    {get, "/users/:id", user_handler, #{}},
    {'_', "/api/*path", api_handler, #{}}
]).

%% Match request
{ok, Handler, Opts, Bindings} = livery_router:match(Router, Method, Path).
{error, not_found} = livery_router:match(Router, Method, Path).

%% Dynamic route management
Router2 = livery_router:add_route({get, "/new", handler, #{}}, Router).
Router3 = livery_router:remove_route({get, "/old"}, Router2).
```

## livery_routing_handler

Meta-handler that routes requests.

```erlang
%% Use as handler with router in opts
livery:start_listener(name, #{
    handler => livery_routing_handler,
    handler_opts => #{
        router => Router,
        not_found_handler => my_404_handler  % optional
    }
}).
```

## livery_middleware

Middleware chain for request/response processing.

```erlang
%% Compile middleware chain
Chain = livery_middleware:compile([Middleware1, Middleware2]).

%% Execute chain
Response = livery_middleware:execute(Chain, Req, HandlerFun).
Response = livery_middleware:execute(Chain, Req, Handler, Opts).

%% Create middleware from before function
Middleware = livery_middleware:before(fun(Req) -> {ok, Req} end).

%% Create middleware from after function
Middleware = livery_middleware:after_response(fun(Response) -> Response end).

%% Create wrapping middleware
Middleware = livery_middleware:wrap(fun(Handler) -> Handler() end).
```

## livery_ws

WebSocket frame encoding/decoding.

```erlang
%% Handshake
true = livery_ws:is_upgrade_request(Headers).
AcceptKey = livery_ws:upgrade_key(ClientKey).
Headers = livery_ws:handshake_response(ClientKey).

%% Frame encoding (server -> client)
Binary = livery_ws:encode_text(Text).
Binary = livery_ws:encode_binary(Data).
Binary = livery_ws:encode_ping(Payload).
Binary = livery_ws:encode_pong(Payload).
Binary = livery_ws:encode_close().
Binary = livery_ws:encode_close(Code).
Binary = livery_ws:encode_close(Code, Reason).

%% Frame decoding (client -> server)
{ok, Opcode, Payload, Fin, Rest} = livery_ws:decode_frame(Data).
{more, N} = livery_ws:decode_frame(PartialData).
```

## livery_compress

Content encoding utilities.

```erlang
%% Decode
{ok, Data} = livery_compress:decode(Compressed, <<"gzip">>).
{ok, Data} = livery_compress:decode(Compressed, <<"deflate">>).

%% Encode
{ok, Compressed} = livery_compress:encode(Data, <<"gzip">>).
{ok, Compressed} = livery_compress:encode(Data, <<"deflate">>).

%% Negotiation
[<<"gzip">>, <<"deflate">>, <<"identity">>] = livery_compress:supported_encodings().
Encoding = livery_compress:negotiate_encoding(AcceptEncodingHeader).
```

## livery_hooks

Hook-based event system for observability.

```erlang
%% Add hooks
Ref = livery_hooks:add(request_stop, fun(Data) ->
    #{method := Method, status := Status} = Data,
    io:format("~s -> ~p~n", [Method, Status])
end).

%% Add hook with tag for identification
Ref = livery_hooks:add(request_stop, MyFun, my_tag).

%% Remove hook
ok = livery_hooks:delete(request_stop, Ref).

%% List hooks for an event
[{Ref, Tag}] = livery_hooks:list(request_stop).

%% Run hooks manually
ok = livery_hooks:run(my_event, #{key => value}).

%% Convenience functions
livery_hooks:connection_start(#{listener => Name, peer => Peer}).
livery_hooks:connection_stop(#{listener => Name, reason => Reason, duration => D}).
livery_hooks:request_start(#{method => Method, path => Path, protocol => h1}).
livery_hooks:request_stop(#{method => M, path => P, status => S, duration => D}).
livery_hooks:request_exception(#{kind => error, reason => R, stacktrace => ST}).
livery_hooks:websocket_upgrade(#{path => Path}).
livery_hooks:websocket_frame(#{direction => in, opcode => text, size => 100}).
```

## livery_info

Server information and statistics.

```erlang
%% Server info
Info = livery_info:info().                    % #{version, listeners, ...}
Version = livery_info:version().              % <<"1.0.0">>

%% Listener info
Info = livery_info:listener_info(Name).       % #{name, acceptors, connections}
AllInfo = livery_info:all_listener_info().    % #{Name => Info}

%% Connection stats
Count = livery_info:connection_count(Name).
Total = livery_info:total_connections().

%% Protocol info
[http1, http2, http3, websocket] = livery_info:supported_protocols().
```

## livery_shutdown

Graceful shutdown support.

```erlang
%% Graceful shutdown (wait for connections)
ok = livery_shutdown:graceful(Name, Timeout).

%% Immediate shutdown
ok = livery_shutdown:immediate(Name).

%% Shutdown all listeners
ok = livery_shutdown:shutdown_all(Timeout).

%% Drain connections (internal use)
ok = livery_shutdown:drain_connections(Connections, Timeout).
```
