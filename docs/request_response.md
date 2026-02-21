# Request and Response

This guide covers the `livery_req` module for accessing request data, `livery_helpers` for common operations, and `livery_resp` for building responses.

## Request API (livery_req)

### Basic Accessors

```erlang
%% HTTP method (binary)
Method = livery_req:method(Req),  % <<"GET">>, <<"POST">>, etc.

%% Path without query string
Path = livery_req:path(Req),  % <<"/users/123">>

%% Query string (raw)
QS = livery_req:qs(Req),  % <<"page=1&limit=10">>

%% HTTP version
Version = livery_req:version(Req),  % {1, 1}, {2, 0}, or {3, 0}

%% All headers as list of tuples
Headers = livery_req:headers(Req),  % [{<<"host">>, <<"example.com">>}, ...]

%% Get specific header
CT = livery_req:header(<<"content-type">>, Req),  % binary() | undefined
CT = livery_req:header(<<"content-type">>, Req, <<"text/plain">>),  % with default

%% Request body
Body = livery_req:body(Req),  % binary() | undefined

%% Check if request has a body
HasBody = livery_req:has_body(Req),  % true | false

%% Get body length
Length = livery_req:body_length(Req),  % integer | chunked | undefined

%% Client peer address
{IP, Port} = livery_req:peer(Req),
```

### Convenience Accessors

```erlang
%% URL scheme
Scheme = livery_req:scheme(Req),  % http | https

%% Host header
Host = livery_req:host(Req),  % <<"example.com">>

%% Server port
Port = livery_req:port(Req),  % 8080

%% Content-Type (stripped of charset/boundary)
CT = livery_req:content_type(Req),  % <<"application/json">>

%% Content-Length as integer
Len = livery_req:content_length(Req),  % 1234 | undefined

%% Accept header
Accept = livery_req:accept(Req),  % <<"text/html, application/json">>

%% User-Agent header
UA = livery_req:user_agent(Req),

%% Check if WebSocket upgrade request
IsWS = livery_req:is_websocket_upgrade(Req),  % true | false

%% Check if SSL connection
IsSSL = livery_req:is_ssl(Req),  % true | false
```

## Helper Functions (livery_helpers)

### Query String Parsing

```erlang
%% Parse query string to map
QS = livery_helpers:parse_qs(Req),
% #{<<"page">> => <<"1">>, <<"limit">> => <<"10">>}

%% Get single value
Page = livery_helpers:get_qs_value(<<"page">>, Req),  % <<"1">>
Page = livery_helpers:get_qs_value(<<"page">>, Req, <<"1">>),  % with default
```

### Form Parsing

```erlang
%% Parse URL-encoded form body
Form = livery_helpers:parse_form(Req),
Username = maps:get(<<"username">>, Form, <<>>),
```

### Multipart Form Data

```erlang
%% Parse multipart/form-data (file uploads)
case livery_helpers:parse_multipart(Req) of
    {ok, Parts} ->
        %% Each part is a map:
        %% #{name => <<"field_name">>, data => <<"content">>,
        %%   filename => <<"file.txt">>,      % optional
        %%   content_type => <<"text/plain">> % optional
        %% }
        handle_parts(Parts);
    {error, no_boundary} ->
        error
end.
```

### JSON Helpers

```erlang
%% Parse JSON body
case livery_helpers:json_body(Req) of
    {ok, Data} ->
        process(Data);
    {error, no_body} ->
        error;
    {error, {invalid_json, _}} ->
        error
end.

%% Send JSON response
handle(_Req, State) ->
    Data = #{status => ok, items => [1, 2, 3]},
    livery_helpers:reply_json(200, Data, State).

%% With extra headers
handle(_Req, State) ->
    Data = #{created => true},
    livery_helpers:reply_json(201, Data, [{<<"x-request-id">>, <<"abc123">>}], State).
```

### Response Helpers

```erlang
%% Plain text response
livery_helpers:reply_text(200, <<"Hello">>, State)

%% HTML response
livery_helpers:reply_html(200, <<"<h1>Hello</h1>">>, State)

%% Serve a file
livery_helpers:reply_file(200, "/path/to/file.html", State)

%% Redirects
livery_helpers:reply_redirect(<<"/new-location">>, State)  % 302
livery_helpers:reply_redirect(301, <<"/permanent">>, State)  % 301

%% Error responses
livery_helpers:reply_not_found(State)                      % 404
livery_helpers:reply_bad_request(<<"Invalid input">>, State)  % 400
livery_helpers:reply_internal_error(<<"Server error">>, State) % 500
```

### Cookie Helpers

```erlang
%% Get cookie from request
SessionId = livery_helpers:get_cookie(<<"session">>, Req),
SessionId = livery_helpers:get_cookie(<<"session">>, Req, <<"default">>),

%% Set cookie in response
{HeaderName, HeaderValue} = livery_helpers:set_cookie(
    <<"session">>,
    <<"abc123">>,
    #{
        path => <<"/">>,
        max_age => 3600,        % 1 hour
        secure => true,
        http_only => true,
        same_site => strict     % strict | lax | none
    }
),
%% Add to response headers

%% Delete cookie
DeleteHeader = livery_helpers:delete_cookie(<<"session">>),
```

### Content Negotiation

```erlang
%% Check if client accepts content type
case livery_helpers:accepts_json(Req) of
    true -> send_json();
    false -> send_html()
end.

%% Check specific type
livery_helpers:accepts(<<"application/xml">>, Req)

%% Find preferred type
Preferred = livery_helpers:preferred_type(
    [<<"application/json">>, <<"text/html">>, <<"text/xml">>],
    Req
),
% Returns first matching type or undefined
```

### Path Bindings

When using the router, path bindings are available:

```erlang
%% In handler, Opts contains bindings from router
handle(Req, Opts) ->
    %% Get single binding
    UserId = livery_helpers:binding(<<"id">>, Opts),
    UserId = livery_helpers:binding(<<"id">>, Opts, <<"default">>),

    %% Get all bindings
    Bindings = livery_helpers:bindings(Opts),
    % #{<<"id">> => <<"123">>, <<"name">> => <<"john">>}
```

## Response Patterns

### Simple Response

```erlang
handle(_Req, State) ->
    {reply, 200,
     [{<<"content-type">>, <<"text/plain">>}],
     <<"Hello, World!">>,
     State}.
```

### No Body Response

```erlang
handle(_Req, State) ->
    {reply, 204, [], State}.  % 204 No Content
```

### JSON Response

```erlang
handle(_Req, State) ->
    Data = #{message => <<"success">>, id => 123},
    Body = json:encode(Data),
    {reply, 200,
     [{<<"content-type">>, <<"application/json">>}],
     Body,
     State}.
```

### Redirect

```erlang
handle(_Req, State) ->
    {reply, 302,
     [{<<"location">>, <<"/new-location">>}],
     <<>>,
     State}.
```

### Error Response

```erlang
handle(_Req, State) ->
    {reply, 400,
     [{<<"content-type">>, <<"application/json">>}],
     <<"{\"error\":\"Bad Request\"}">>,
     State}.
```

## Response Building (livery_resp)

The `livery_resp` module provides low-level response building:

```erlang
%% Build complete response
Response = livery_resp:build(200, Headers, Body, {1, 1}),

%% Build response without body
Response = livery_resp:build(204, Headers, {1, 1}),

%% Get status text
Text = livery_resp:status_text(404),  % <<"Not Found">>
```

### Chunked Encoding

```erlang
%% Build chunked response start
Start = livery_resp:build_chunked_start(200, Headers, {1, 1}),

%% Encode a chunk
Chunk = livery_resp:encode_chunk(Data),

%% Encode last chunk (no trailers)
Last = livery_resp:encode_last_chunk(),

%% Encode last chunk with trailers
Last = livery_resp:encode_last_chunk([{<<"x-checksum">>, <<"abc">>}]),
```
