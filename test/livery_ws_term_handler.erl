%% @doc Server-side `ws_handler' used by livery_ws_SUITE.
%%
%% Emits a `ready' frame on connect and reports its terminate reason to
%% the pid given as `notify', so a test can assert the peer's close code
%% surfaced as `{remote, Code, Reason}'.
-module(livery_ws_term_handler).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, #{notify := Parent} = Opts) when is_pid(Parent) ->
    {reply, [{text, <<"ready">>}], Opts}.

handle_in(_Frame, State) ->
    {ok, State}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(Reason, #{notify := Parent}) ->
    Parent ! {ws_server_terminate, Reason},
    ok.
