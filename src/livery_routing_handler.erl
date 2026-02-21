%% @doc Meta-handler that routes requests to other handlers.
%%
%% This module provides a convenient way to integrate the router with handlers.
%% Instead of manually routing in each handler, you can use this as your handler
%% and let it dispatch to the appropriate handler based on the router configuration.
%%
%% Usage:
%% ```
%% Routes = [
%%     {get, "/", home_handler, #{}},
%%     {get, "/users/:id", user_handler, #{}},
%%     {post, "/users", user_create_handler, #{}}
%% ],
%% Router = livery_router:compile(Routes),
%% livery:start_listener(my_http, #{
%%     handler => livery_routing_handler,
%%     handler_opts => #{router => Router}
%% }).
%% '''
%%
%% The matched handler receives the request with bindings available via
%% `livery_helpers:bindings/1` and `livery_helpers:binding/2,3`.
-module(livery_routing_handler).

-behaviour(livery_handler).

-include("livery.hrl").

-export([init/2, handle/2, terminate/2]).

%% State that tracks the delegated handler
-record(state, {
    handler :: module(),
    handler_state :: term()
}).

-type state() :: #state{} | not_found | method_not_allowed | no_router.

%% @doc Initialize and route to the appropriate handler.
-spec init(#livery_req{} | map(), term()) ->
    {ok, #livery_req{} | map(), state()} |
    {websocket, #livery_req{} | map(), state()} |
    {error, term()}.
init(Req, #{router := Router} = Opts) ->
    Method = livery_req:method(Req),
    Path = livery_req:path(Req),
    case livery_router:match(Router, Method, Path) of
        {ok, Handler, HandlerOpts, Bindings} ->
            %% Merge bindings into handler opts
            MergedOpts = case is_map(HandlerOpts) of
                true -> HandlerOpts#{bindings => Bindings};
                false -> #{bindings => Bindings, opts => HandlerOpts}
            end,
            %% Delegate to the actual handler
            case Handler:init(Req, MergedOpts) of
                {ok, Req2, HandlerState} ->
                    {ok, Req2, #state{handler = Handler, handler_state = HandlerState}};
                {websocket, Req2, HandlerState} ->
                    {websocket, Req2, #state{handler = Handler, handler_state = HandlerState}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, not_found} ->
            %% Check for custom 404 handler
            case maps:get(not_found_handler, Opts, undefined) of
                undefined ->
                    {ok, Req, not_found};
                NotFoundHandler ->
                    case NotFoundHandler:init(Req, #{}) of
                        {ok, Req2, HandlerState} ->
                            {ok, Req2, #state{handler = NotFoundHandler, handler_state = HandlerState}};
                        Other ->
                            Other
                    end
            end;
        {error, method_not_allowed} ->
            {ok, Req, method_not_allowed}
    end;
init(Req, _Opts) ->
    %% No router provided
    {ok, Req, no_router}.

%% @doc Handle request by delegating to matched handler.
-spec handle(#livery_req{}, state()) ->
    {reply, non_neg_integer(), [{binary(), binary()}], iodata(), state()} |
    {reply, non_neg_integer(), [{binary(), binary()}], state()} |
    {stream, non_neg_integer(), [{binary(), binary()}], fun(), state()} |
    {error, term(), state()}.
handle(_Req, not_found) ->
    {reply, 404, [{<<"content-type">>, <<"text/plain">>}], <<"Not Found">>, not_found};
handle(_Req, method_not_allowed) ->
    {reply, 405, [{<<"content-type">>, <<"text/plain">>}], <<"Method Not Allowed">>, method_not_allowed};
handle(_Req, no_router) ->
    {reply, 500, [{<<"content-type">>, <<"text/plain">>}], <<"Router not configured">>, no_router};
handle(Req, #state{handler = Handler, handler_state = HandlerState} = State) ->
    case Handler:handle(Req, HandlerState) of
        {reply, Status, Headers, Body, NewHandlerState} ->
            {reply, Status, Headers, Body, State#state{handler_state = NewHandlerState}};
        {reply, Status, Headers, NewHandlerState} ->
            {reply, Status, Headers, State#state{handler_state = NewHandlerState}};
        {stream, Status, Headers, StreamFun, NewHandlerState} ->
            {stream, Status, Headers, StreamFun, State#state{handler_state = NewHandlerState}};
        {error, Reason, NewHandlerState} ->
            {error, Reason, State#state{handler_state = NewHandlerState}}
    end.

%% @doc Terminate by delegating to matched handler.
-spec terminate(normal | {error, term()}, state()) -> ok.
terminate(Reason, #state{handler = Handler, handler_state = HandlerState}) ->
    case erlang:function_exported(Handler, terminate, 2) of
        true -> Handler:terminate(Reason, HandlerState);
        false -> ok
    end;
terminate(_Reason, _State) ->
    ok.
