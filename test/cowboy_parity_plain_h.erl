%% @doc Cowboy equivalent of livery_example_migration:plain/1.
%% Test-only; mirrors Livery's exact observable response.
-module(cowboy_parity_plain_h).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
        <<"Hello world!">>,
        Req0
    ),
    {ok, Req, State}.
