-module(hello_handler).
-behaviour(livery_handler).

-export([init/2, handle/2, terminate/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, State) ->
    Path = livery_req:path(Req),
    case Path of
        <<"/">> ->
            {reply, 200, [{<<"content-type">>, <<"text/plain">>}],
             <<"Hello, World!">>, State};
        <<"/greet/", _/binary>> ->
            Name = livery_helpers:binding(<<"name">>, State),
            Body = <<"Hello, ", Name/binary, "!">>,
            {reply, 200, [{<<"content-type">>, <<"text/plain">>}], Body, State};
        _ ->
            {reply, 404, [{<<"content-type">>, <<"text/plain">>}],
             <<"Not Found">>, State}
    end.

terminate(_Reason, _State) ->
    ok.
