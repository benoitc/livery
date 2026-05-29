%% @doc Cowboy equivalent of livery_example_migration:events/1 (SSE).
%% Test-only. Emits the same fixed `event: tick / data: N' frames Livery's
%% sse builder produces (src/livery.erl sse_frame/1).
-module(cowboy_parity_sse_h).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req = cowboy_req:stream_reply(
        200,
        #{
            <<"content-type">> => <<"text/event-stream">>,
            <<"cache-control">> => <<"no-cache">>
        },
        Req0
    ),
    lists:foreach(
        fun(N) ->
            Frame = [<<"event: tick\ndata: ">>, integer_to_binary(N), <<"\n\n">>],
            cowboy_req:stream_body(Frame, nofin, Req)
        end,
        [1, 2, 3]
    ),
    cowboy_req:stream_body(<<>>, fin, Req),
    {ok, Req, State}.
