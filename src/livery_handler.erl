%% @doc Handler behaviour for Livery HTTP server.
%%
%% Implement this behaviour to handle HTTP requests.
%%
%% Example:
%% ```
%% -module(my_handler).
%% -behaviour(livery_handler).
%% -export([init/2, handle/2, terminate/2]).
%%
%% init(Req, Opts) ->
%%     {ok, Req, #{opts => Opts}}.
%%
%% handle(Req, State) ->
%%     {reply, 200, [{<<"content-type">>, <<"text/plain">>}], <<"Hello!">>, State}.
%%
%% terminate(_Reason, _State) ->
%%     ok.
%% '''
%%
%% WebSocket over HTTP/3 Example (RFC 9220):
%% ```
%% -module(my_ws_handler).
%% -behaviour(livery_handler).
%% -export([init/2, handle/2, websocket_handle/2]).
%%
%% init(Req, Opts) ->
%%     case maps:get(protocol, Req, undefined) of
%%         websocket -> {websocket, Req, #{}};
%%         _ -> {ok, Req, #{}}
%%     end.
%%
%% handle(Req, State) ->
%%     {reply, 200, [], <<"Hello">>, State}.
%%
%% websocket_handle({text, Text}, State) ->
%%     {reply, {text, Text}, State};  %% Echo
%% websocket_handle({ping, Payload}, State) ->
%%     {reply, {pong, Payload}, State};
%% websocket_handle({close, _Code, _}, State) ->
%%     {stop, normal, State}.
%% '''
-module(livery_handler).

-include("livery.hrl").

%% Callbacks

%% @doc Initialize handler state.
%% Called when a new request arrives.
%% Return `{ok, Req, State}' to proceed with handling.
%% Return `{websocket, Req, State}' to accept WebSocket upgrade (HTTP/3 RFC 9220).
%% Return `{error, Reason}' to abort the request.
-callback init(Req :: #livery_req{} | map(), Opts :: term()) ->
    {ok, #livery_req{} | map(), State :: term()} |
    {websocket, #livery_req{} | map(), State :: term()} |
    {error, Reason :: term()}.

%% @doc Handle the request.
%% Return a response tuple to send a response to the client.
%%
%% Response types:
%% - `{reply, Status, Headers, Body, State}' - Send a complete response
%% - `{reply, Status, Headers, State}' - Send response with no body
%% - `{stream, Status, Headers, StreamFun, State}' - Stream chunked response
%% - `{error, Reason, State}' - Return an error
%%
%% StreamFun is a function that will be called with a send function:
%%   `StreamFun(SendFun)' where `SendFun(Chunk)' sends a chunk.
%%   Call `SendFun(done)' or `SendFun({done, Trailers})' to finish.
-callback handle(Req :: #livery_req{}, State :: term()) ->
    {reply, Status :: non_neg_integer(), Headers :: [{binary(), binary()}],
     Body :: iodata(), NewState :: term()} |
    {reply, Status :: non_neg_integer(), Headers :: [{binary(), binary()}],
     NewState :: term()} |
    {stream, Status :: non_neg_integer(), Headers :: [{binary(), binary()}],
     StreamFun :: fun((SendFun :: fun((iodata() | done | {done, [{binary(), binary()}]}) -> ok)) -> ok),
     NewState :: term()} |
    {error, Reason :: term(), NewState :: term()}.

%% @doc Clean up handler state.
%% Called when the request processing is finished.
-callback terminate(Reason :: normal | {error, term()}, State :: term()) -> ok.

%% @doc Handle incoming WebSocket frames (RFC 9220).
%% Called when a WebSocket frame is received from the client.
%% Return `{ok, State}' to continue without sending a response.
%% Return `{reply, Frame, State}' to send a response frame.
%% Return `{stop, Reason, State}' to close the WebSocket.
-callback websocket_handle(Frame :: livery_ws:frame(), State :: term()) ->
    {ok, NewState :: term()} |
    {reply, Frame :: livery_ws:frame(), NewState :: term()} |
    {stop, Reason :: term(), NewState :: term()}.

%% @doc Handle Erlang messages sent to the handler process.
%% Called when the handler receives an info message (e.g., from a timer or another process).
%% Return values are the same as websocket_handle/2.
-callback websocket_info(Info :: term(), State :: term()) ->
    {ok, NewState :: term()} |
    {reply, Frame :: livery_ws:frame(), NewState :: term()} |
    {stop, Reason :: term(), NewState :: term()}.

%% Optional callbacks
-optional_callbacks([terminate/2, websocket_handle/2, websocket_info/2]).
