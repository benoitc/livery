%% @doc Cowboy equivalent of livery_example_migration:stream/1 (chunked
%% NDJSON, the cowboy_loop replacement). Test-only. Emits the same fixed
%% `{"n":N}\n' lines Livery's ndjson builder produces.
-module(cowboy_parity_stream_h).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req = cowboy_req:stream_reply(
        200,
        #{<<"content-type">> => <<"application/x-ndjson">>},
        Req0
    ),
    lists:foreach(
        fun(N) ->
            Line = [<<"{\"n\":">>, integer_to_binary(N), <<"}\n">>],
            cowboy_req:stream_body(Line, nofin, Req)
        end,
        [1, 2, 3]
    ),
    cowboy_req:stream_body(<<>>, fin, Req),
    {ok, Req, State}.
