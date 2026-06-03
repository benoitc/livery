%% @doc Cowboy reference handler for the livery_bench comparison.
%% Mirrors livery_bench:ref_handler/0 byte-for-byte: a 200 with
%% content-type application/json and body {"ok":true}.
-module(bench_cowboy_h).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        <<"{\"ok\":true}">>,
        Req0
    ),
    {ok, Req, State}.
