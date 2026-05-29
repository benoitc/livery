%% @doc Cowboy equivalent of livery_example_migration:thing/1
%% (GET /things/:id). Test-only.
-module(cowboy_parity_thing_h).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req =
        case cowboy_req:binding(id, Req0) of
            <<"1">> ->
                cowboy_req:reply(
                    200,
                    #{<<"content-type">> => <<"application/json">>},
                    <<"{\"id\":1,\"name\":\"alpha\"}">>,
                    Req0
                );
            _ ->
                cowboy_req:reply(
                    404,
                    #{<<"content-type">> => <<"application/json">>},
                    <<"{\"error\":\"not found\"}">>,
                    Req0
                )
        end,
    {ok, Req, State}.
