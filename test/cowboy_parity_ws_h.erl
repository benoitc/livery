%% @doc Cowboy equivalent of the /ws echo in livery_example_migration.
%% Test-only. Plain echo, no readiness frame.
-module(cowboy_parity_ws_h).
-behaviour(cowboy_websocket).

-export([init/2, websocket_handle/2, websocket_info/2]).

init(Req, State) ->
    {cowboy_websocket, Req, State}.

websocket_handle({text, Bin}, State) ->
    {[{text, Bin}], State};
websocket_handle({binary, Bin}, State) ->
    {[{binary, Bin}], State};
websocket_handle(_Frame, State) ->
    {[], State}.

websocket_info(_Info, State) ->
    {[], State}.
