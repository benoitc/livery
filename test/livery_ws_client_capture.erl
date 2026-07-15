%% @doc Client-side `ws_handler' used by livery_ws_SUITE.
%%
%% Forwards the handshake `Req' (as `{ws_init, Req}') and then every
%% inbound frame (as `{captured, Frame}') to the test process supplied as
%% `handler_opts'. The `ws_init' message lets a test read the negotiated
%% subprotocol from `Req' = `#{response := #{subprotocol := _}}'.
-module(livery_ws_client_capture).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(Req, #{parent := Parent} = _Opts) ->
    Parent ! {ws_init, Req},
    {ok, Parent}.

handle_in(Frame, Parent) when is_pid(Parent) ->
    Parent ! {captured, Frame},
    {ok, Parent}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
