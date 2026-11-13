%% An adapter that implements nothing but the two upgrade callbacks, as
%% one written outside Livery might. Each reports what it received to the
%% process registered as livery_upgrade_probe.
-module(livery_upgrade_fake_adapter).

-export([accept_ws/4, accept_wt/4]).

accept_ws(Stream, _Req, HandlerMod, _Opts) ->
    livery_upgrade_probe ! {accept_ws, Stream, HandlerMod},
    {ok, self()}.

accept_wt(Stream, _Req, HandlerMod, _Opts) ->
    livery_upgrade_probe ! {accept_wt, Stream, HandlerMod},
    {ok, self()}.
