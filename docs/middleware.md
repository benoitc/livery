# Middleware

Middleware allows you to intercept and transform requests and responses. Livery provides a functional middleware system that wraps handler execution.

## Middleware Concept

Middleware are functions that wrap request handling:

```erlang
fun(Req, Next) ->
    %% Before handler
    io:format("Request: ~s~n", [livery_req:path(Req)]),

    %% Call next middleware/handler
    {Status, Headers, Body, Req1} = Next(Req),

    %% After handler
    io:format("Response: ~p~n", [Status]),

    %% Return response (possibly modified)
    {Status, Headers, Body, Req1}
end
```

## Creating Middleware

### Basic Middleware

```erlang
LoggingMiddleware = fun(Req, Next) ->
    Start = erlang:monotonic_time(microsecond),
    {Status, Headers, Body, Req1} = Next(Req),
    Duration = erlang:monotonic_time(microsecond) - Start,
    error_logger:info_msg("~s ~s -> ~p (~p us)~n",
        [livery_req:method(Req), livery_req:path(Req), Status, Duration]),
    {Status, Headers, Body, Req1}
end.
```

### Short-Circuiting Middleware

```erlang
AuthMiddleware = fun(Req, Next) ->
    case check_auth(Req) of
        ok ->
            Next(Req);
        error ->
            {401, [], <<"Unauthorized">>, Req}
    end
end.
```

## Compiling Middleware Chain

```erlang
%% Create middleware chain
Chain = livery_middleware:compile([
    LoggingMiddleware,
    AuthMiddleware,
    CorsMiddleware
]).
```

Middleware are executed in order, with the first middleware being the outermost wrapper.

## Executing Middleware

```erlang
%% Execute with handler function
Result = livery_middleware:execute(Chain, Req, fun(Req1) ->
    {200, [], <<"Hello">>, Req1}
end).

%% Execute with handler module and options
Result = livery_middleware:execute(Chain, Req, MyHandler, Opts).
```

## Middleware Helpers

### Before Middleware

Transform requests before the handler:

```erlang
BeforeMiddleware = livery_middleware:before(fun(Req) ->
    case validate_request(Req) of
        ok ->
            {ok, Req};
        {error, Reason} ->
            {error, {400, [], Reason}}
    end
end).
```

### After Middleware

Transform responses after the handler:

```erlang
AfterMiddleware = livery_middleware:after_response(fun({Status, Headers, Body, Req}) ->
    %% Add custom header to all responses
    NewHeaders = [{<<"x-powered-by">>, <<"Livery">>} | Headers],
    {Status, NewHeaders, Body, Req}
end).
```

### Wrap Middleware

Wrap handler execution (for error handling, timing, etc.):

```erlang
ErrorMiddleware = livery_middleware:wrap(fun(Handler) ->
    try
        Handler()
    catch
        error:Reason:Stack ->
            error_logger:error_msg("Handler error: ~p~n~p~n", [Reason, Stack]),
            {500, [], <<"Internal Server Error">>, undefined}
    end
end).
```

## Common Middleware Examples

### CORS Middleware

```erlang
cors_middleware(AllowedOrigins) ->
    fun(Req, Next) ->
        case livery_req:method(Req) of
            <<"OPTIONS">> ->
                %% Preflight request
                {204, cors_headers(AllowedOrigins), <<>>, Req};
            _ ->
                {Status, Headers, Body, Req1} = Next(Req),
                {Status, cors_headers(AllowedOrigins) ++ Headers, Body, Req1}
        end
    end.

cors_headers(Origins) ->
    [
        {<<"access-control-allow-origin">>, Origins},
        {<<"access-control-allow-methods">>, <<"GET, POST, PUT, DELETE, OPTIONS">>},
        {<<"access-control-allow-headers">>, <<"Content-Type, Authorization">>},
        {<<"access-control-max-age">>, <<"86400">>}
    ].
```

### Authentication Middleware

```erlang
auth_middleware(Secret) ->
    fun(Req, Next) ->
        case livery_req:header(<<"authorization">>, Req) of
            <<"Bearer ", Token/binary>> ->
                case verify_token(Token, Secret) of
                    {ok, UserId} ->
                        %% Store user ID for handler access
                        put(user_id, UserId),
                        Next(Req);
                    error ->
                        {401, [], <<"{\"error\":\"Invalid token\"}">>, Req}
                end;
            _ ->
                {401, [], <<"{\"error\":\"Authorization required\"}">>, Req}
        end
    end.
```

### Rate Limiting Middleware

```erlang
rate_limit_middleware(MaxRequests, WindowSeconds) ->
    fun(Req, Next) ->
        {IP, _} = livery_req:peer(Req),
        Key = {rate_limit, IP},
        Now = erlang:system_time(second),

        case ets:lookup(rate_limits, Key) of
            [{_, Count, WindowStart}] when Now - WindowStart < WindowSeconds ->
                if
                    Count >= MaxRequests ->
                        {429, [], <<"Too Many Requests">>, Req};
                    true ->
                        ets:update_counter(rate_limits, Key, {2, 1}),
                        Next(Req)
                end;
            _ ->
                ets:insert(rate_limits, {Key, 1, Now}),
                Next(Req)
        end
    end.
```

### Request Logging Middleware

```erlang
logging_middleware() ->
    fun(Req, Next) ->
        Start = erlang:monotonic_time(microsecond),
        Method = livery_req:method(Req),
        Path = livery_req:path(Req),
        {IP, _} = livery_req:peer(Req),

        {Status, Headers, Body, Req1} = Next(Req),

        Duration = erlang:monotonic_time(microsecond) - Start,
        BodySize = byte_size(iolist_to_binary(Body)),

        error_logger:info_msg(
            "~s ~s ~s -> ~p (~p us, ~p bytes)~n",
            [inet:ntoa(IP), Method, Path, Status, Duration, BodySize]
        ),

        {Status, Headers, Body, Req1}
    end.
```

### JSON Body Parser Middleware

```erlang
json_body_middleware() ->
    livery_middleware:before(fun(Req) ->
        case livery_req:content_type(Req) of
            <<"application/json">> ->
                case livery_helpers:json_body(Req) of
                    {ok, Data} ->
                        put(json_body, Data),
                        {ok, Req};
                    {error, _} ->
                        {error, {400, [], <<"Invalid JSON">>}}
                end;
            _ ->
                {ok, Req}
        end
    end).
```

## Using Middleware with Handlers

### Manual Integration

```erlang
-module(my_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    %% Compile middleware chain once (or compile at startup)
    Chain = livery_middleware:compile([
        logging_middleware(),
        cors_middleware(<<"*">>),
        auth_middleware(<<"secret">>)
    ]),
    {ok, Req, #{chain => Chain, opts => Opts}}.

handle(Req, #{chain := Chain} = State) ->
    %% Execute through middleware
    Result = livery_middleware:execute(Chain, Req, fun(Req1) ->
        do_handle(Req1)
    end),
    case Result of
        {Status, Headers, Body, _} ->
            {reply, Status, Headers, Body, State}
    end.

do_handle(Req) ->
    %% Your handler logic here
    {200, [{<<"content-type">>, <<"application/json">>}], <<"{}">>, Req}.
```

### Middleware Handler Wrapper

Create a generic middleware-aware handler:

```erlang
-module(middleware_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, #{handler := Handler, middleware := Middleware} = Opts) ->
    Chain = livery_middleware:compile(Middleware),
    case Handler:init(Req, Opts) of
        {ok, Req2, HandlerState} ->
            {ok, Req2, #{chain => Chain, handler => Handler, state => HandlerState}};
        Other ->
            Other
    end.

handle(Req, #{chain := Chain, handler := Handler, state := HandlerState} = State) ->
    Result = livery_middleware:execute(Chain, Req, Handler, HandlerState),
    case Result of
        {Status, Headers, Body, _} ->
            {reply, Status, Headers, Body, State};
        {stream, Status, Headers, StreamFun, _} ->
            {stream, Status, Headers, StreamFun, State}
    end.
```

Usage:

```erlang
livery:start_listener(my_http, #{
    port => 8080,
    handler => middleware_handler,
    handler_opts => #{
        handler => my_api_handler,
        middleware => [
            logging_middleware(),
            cors_middleware(<<"*">>)
        ]
    }
}).
```
