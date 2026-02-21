%% @doc Middleware chain for request/response processing.
%%
%% Middleware are functions that wrap request handling, allowing
%% pre-processing of requests and post-processing of responses.
%%
%% Middleware types:
%% - Before middleware: Transform request before handler
%% - After middleware: Transform response after handler
%% - Around middleware: Wrap handler execution
%%
%% Example:
%% ```
%% %% Logging middleware
%% LoggingMiddleware = fun(Req, Next) ->
%%     io:format("Request: ~p~n", [livery_req:path(Req)]),
%%     {Status, Headers, Body, Req1} = Next(Req),
%%     io:format("Response: ~p~n", [Status]),
%%     {Status, Headers, Body, Req1}
%% end,
%%
%% %% Auth middleware
%% AuthMiddleware = fun(Req, Next) ->
%%     case check_auth(Req) of
%%         ok -> Next(Req);
%%         error -> {401, [], <<"Unauthorized">>, Req}
%%     end
%% end,
%%
%% Chain = livery_middleware:compile([LoggingMiddleware, AuthMiddleware]),
%% Result = livery_middleware:execute(Chain, Req, Handler).
%% '''
-module(livery_middleware).

-export([
    compile/1,
    execute/3,
    execute/4,
    before/1,
    after_response/1,
    wrap/1
]).

-type request() :: term().
-type response() :: {integer(), [{binary(), binary()}], iodata(), request()}.
-type next_fun() :: fun((request()) -> response()).
-type middleware() :: fun((request(), next_fun()) -> response()).
-type before_middleware() :: fun((request()) -> {ok, request()} | {error, response()}).
-type after_middleware() :: fun((response()) -> response()).
-type compiled() :: fun((request(), fun((request()) -> response())) -> response()).

-export_type([middleware/0, before_middleware/0, after_middleware/0, compiled/0]).

%%====================================================================
%% API
%%====================================================================

%% @doc Compile a list of middleware into a single function.
%% Middleware are executed in order, with the first middleware being
%% the outermost wrapper.
-spec compile([middleware()]) -> compiled().
compile([]) ->
    fun(Req, Handler) -> Handler(Req) end;
compile(Middlewares) ->
    lists:foldr(fun(Middleware, Next) ->
        fun(Req, Handler) ->
            Middleware(Req, fun(Req1) -> Next(Req1, Handler) end)
        end
    end, fun(Req, Handler) -> Handler(Req) end, Middlewares).

%% @doc Execute middleware chain with a handler.
-spec execute(compiled(), request(), fun((request()) -> response())) -> response().
execute(Chain, Req, Handler) ->
    Chain(Req, Handler).

%% @doc Execute middleware chain with handler module and options.
-spec execute(compiled(), request(), module(), term()) -> response().
execute(Chain, Req, Handler, Opts) ->
    Chain(Req, fun(Req1) ->
        case Handler:init(Req1, Opts) of
            {ok, Req2, State} ->
                case Handler:handle(Req2, State) of
                    {reply, Status, Headers, Body, _State1} ->
                        {Status, Headers, Body, Req2};
                    {reply, Status, Headers, _State1} ->
                        {Status, Headers, <<>>, Req2};
                    {stream, Status, Headers, StreamFun, _State1} ->
                        {stream, Status, Headers, StreamFun, Req2};
                    {error, Reason, _State1} ->
                        {500, [], iolist_to_binary(io_lib:format("~p", [Reason])), Req2}
                end;
            {error, Reason} ->
                {500, [], iolist_to_binary(io_lib:format("~p", [Reason])), Req1}
        end
    end).

%% @doc Create a middleware from a before-request function.
%% The function receives the request and returns {ok, NewReq} to continue
%% or {error, Response} to short-circuit with a response.
-spec before(before_middleware()) -> middleware().
before(BeforeFun) ->
    fun(Req, Next) ->
        case BeforeFun(Req) of
            {ok, Req1} ->
                Next(Req1);
            {error, {Status, Headers, Body}} ->
                {Status, Headers, Body, Req}
        end
    end.

%% @doc Create a middleware from an after-response function.
%% The function receives the response tuple and can transform it.
-spec after_response(after_middleware()) -> middleware().
after_response(AfterFun) ->
    fun(Req, Next) ->
        Response = Next(Req),
        AfterFun(Response)
    end.

%% @doc Create a middleware that wraps handler execution.
%% Useful for try/catch, timing, etc.
-spec wrap(fun((fun(() -> response())) -> response())) -> middleware().
wrap(WrapFun) ->
    fun(Req, Next) ->
        WrapFun(fun() -> Next(Req) end)
    end.

%%====================================================================
%% Built-in middleware constructors
%%====================================================================

%% Note: These are examples that can be used as-is or as templates.
%% They are not exported by default to keep the module focused.

%% Logging middleware example:
%% logging() ->
%%     fun(Req, Next) ->
%%         Start = erlang:monotonic_time(microsecond),
%%         {Status, Headers, Body, Req1} = Next(Req),
%%         End = erlang:monotonic_time(microsecond),
%%         Duration = End - Start,
%%         error_logger:info_msg("~s ~s -> ~p (~p us)~n",
%%             [livery_req:method(Req), livery_req:path(Req), Status, Duration]),
%%         {Status, Headers, Body, Req1}
%%     end.

%% CORS middleware example:
%% cors(AllowedOrigins) ->
%%     fun(Req, Next) ->
%%         {Status, Headers, Body, Req1} = Next(Req),
%%         Origin = livery_req:header(<<"origin">>, Req),
%%         CorsHeaders = case lists:member(Origin, AllowedOrigins) of
%%             true ->
%%                 [{<<"access-control-allow-origin">>, Origin},
%%                  {<<"access-control-allow-methods">>, <<"GET, POST, PUT, DELETE, OPTIONS">>},
%%                  {<<"access-control-allow-headers">>, <<"Content-Type, Authorization">>}];
%%             false ->
%%                 []
%%         end,
%%         {Status, CorsHeaders ++ Headers, Body, Req1}
%%     end.

%% Error handling middleware example:
%% error_handler() ->
%%     wrap(fun(Handler) ->
%%         try
%%             Handler()
%%         catch
%%             error:Reason:Stack ->
%%                 error_logger:error_msg("Handler error: ~p~n~p~n", [Reason, Stack]),
%%                 {500, [], <<"Internal Server Error">>, undefined}
%%         end
%%     end).
