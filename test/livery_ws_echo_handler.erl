%% @doc Tiny ws_handler used by livery_ws_SUITE.
%%
%% Emits a `ready' text frame on connect so the test can confirm the
%% upgraded stream is live before sending its own frame (closing a
%% lost-frame race), then echoes every text frame back to the client,
%% replies to pings, and exits cleanly on close.
-module(livery_ws_echo_handler).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, _Opts) ->
    {reply, [{text, <<"ready">>}], undefined}.

handle_in({text, Bin}, State) ->
    {reply, [{text, Bin}], State};
handle_in({binary, Bin}, State) ->
    {reply, [{binary, Bin}], State};
handle_in({ping, Bin}, State) ->
    {reply, [{pong, Bin}], State};
handle_in({close, Code, _Reason}, State) ->
    {stop, {peer_closed, Code}, State};
handle_in(_Frame, State) ->
    {ok, State}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
