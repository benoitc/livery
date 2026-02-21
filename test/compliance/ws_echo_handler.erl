%% @doc WebSocket echo handler for Autobahn compliance testing.
%%
%% Implements the WebSocket echo protocol required by Autobahn|Testsuite:
%% - Echoes all text and binary messages back
%% - Responds to ping with pong
%% - Handles close frames properly
-module(ws_echo_handler).

-behaviour(livery_handler).

-export([init/2, handle/2, terminate/2]).
-export([websocket_init/1, websocket_handle/2, websocket_info/2]).

-include_lib("livery/include/livery.hrl").

%%====================================================================
%% HTTP handler callbacks (for upgrade)
%%====================================================================

init(Req, Opts) ->
    %% Check if this is a WebSocket upgrade request
    Headers = livery_req:headers(Req),
    case livery_ws:is_upgrade_request(Headers) of
        true ->
            %% Upgrade to WebSocket
            {websocket, Req, #{opts => Opts}};
        false ->
            %% Regular HTTP request
            {ok, Req, #{opts => Opts}}
    end.

handle(_Req, State) ->
    %% Non-WebSocket request - return instructions
    Body = <<"WebSocket Echo Server\n\n",
             "Connect via WebSocket to /ws for echo testing.\n",
             "This server echoes all messages for Autobahn compliance testing.">>,
    {reply, 200, [{<<"content-type">>, <<"text/plain">>}], Body, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% WebSocket callbacks
%%====================================================================

%% @doc Called when WebSocket connection is established.
websocket_init(State) ->
    {ok, State}.

%% @doc Handle incoming WebSocket frames.
websocket_handle({text, Text}, State) ->
    %% Echo text message back
    {reply, {text, Text}, State};

websocket_handle({binary, Data}, State) ->
    %% Echo binary message back
    {reply, {binary, Data}, State};

websocket_handle({ping, Payload}, State) ->
    %% Respond with pong
    {reply, {pong, Payload}, State};

websocket_handle({pong, _Payload}, State) ->
    %% Ignore pong frames
    {ok, State};

websocket_handle({close, Code, Reason}, State) ->
    %% Echo close frame and close connection
    {stop, {close, Code, Reason}, State};

websocket_handle(_Frame, State) ->
    %% Ignore unknown frames
    {ok, State}.

%% @doc Handle Erlang messages sent to WebSocket process.
websocket_info({send, Frame}, State) ->
    %% Allow sending frames via Erlang messages
    {reply, Frame, State};

websocket_info(_Info, State) ->
    {ok, State}.
