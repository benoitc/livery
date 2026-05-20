%% @doc Client-side `ws_handler' used by livery_ws_SUITE.
%%
%% Forwards every inbound frame to the test process supplied as
%% `handler_opts'.
-module(livery_ws_client_capture).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, #{parent := Parent} = _Opts) ->
    {ok, Parent}.

handle_in(Frame, Parent) when is_pid(Parent) ->
    Parent ! {captured, Frame},
    {ok, Parent}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
