%% @doc Cowboy reference handler for the livery_bench comparison.
%% Mirrors livery_bench:ref_handler/0: a tiny JSON GET on `/', a sized
%% response on `GET /bytes/<n>', and a JSON echo on `POST /echo'.
-module(bench_cowboy_h).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req = route(cowboy_req:method(Req0), cowboy_req:path(Req0), Req0),
    {ok, Req, State}.

route(<<"POST">>, <<"/echo">>, Req0) ->
    {Body, Req1} = read_body(Req0, <<>>),
    cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, Body, Req1);
route(<<"GET">>, <<"/bytes/", N/binary>>, Req0) ->
    Payload = binary:copy(<<"x">>, binary_to_integer(N)),
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>}, Payload, Req0);
route(_Method, _Path, Req0) ->
    cowboy_req:reply(
        200, #{<<"content-type">> => <<"application/json">>}, <<"{\"ok\":true}">>, Req0
    ).

read_body(Req0, Acc) ->
    case cowboy_req:read_body(Req0) of
        {ok, Data, Req1} -> {<<Acc/binary, Data/binary>>, Req1};
        {more, Data, Req1} -> read_body(Req1, <<Acc/binary, Data/binary>>)
    end.
