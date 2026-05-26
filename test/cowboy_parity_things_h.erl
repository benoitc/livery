%% @doc Cowboy equivalent of the /things resource in
%% livery_example_migration (GET list, POST create, 405 otherwise).
%% Test-only; mirrors Livery's plain-handler method dispatch, including
%% the router's 405 + Allow and "method not allowed" body.
-module(cowboy_parity_things_h).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req =
        case cowboy_req:method(Req0) of
            <<"GET">> ->
                cowboy_req:reply(
                    200,
                    #{<<"content-type">> => <<"application/json">>},
                    <<"[{\"id\":1,\"name\":\"alpha\"}]">>,
                    Req0
                );
            <<"POST">> ->
                {ok, Body, Req1} = cowboy_req:read_body(Req0),
                N = integer_to_binary(byte_size(Body)),
                Json = <<"{\"id\":1,\"received\":", N/binary, "}">>,
                cowboy_req:reply(
                    201,
                    #{
                        <<"content-type">> => <<"application/json">>,
                        <<"location">> => <<"/things/1">>
                    },
                    Json,
                    Req1
                );
            _ ->
                cowboy_req:reply(
                    405,
                    #{
                        <<"content-type">> => <<"text/plain; charset=utf-8">>,
                        <<"allow">> => <<"GET, POST">>
                    },
                    <<"method not allowed">>,
                    Req0
                )
        end,
    {ok, Req, State}.
