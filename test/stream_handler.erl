-module(stream_handler).
-behaviour(livery_handler).

-export([init/2, handle/2, terminate/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(_Req, State) ->
    Action = maps:get(action, State, undefined),
    case Action of
        stream ->
            StreamFun = fun(Send) ->
                Send(<<"chunk1">>),
                Send(<<"chunk2">>),
                Send(<<"chunk3">>),
                Send(done)
            end,
            {stream, 200, [{<<"content-type">>, <<"text/plain">>}], StreamFun, State};
        large ->
            %% 1MB of data
            Data = binary:copy(<<"X">>, 1024 * 1024),
            {reply, 200, [{<<"content-type">>, <<"application/octet-stream">>}], Data, State};
        sse ->
            StreamFun = fun(Send) ->
                Send(<<"event: message\ndata: event1\n\n">>),
                Send(<<"event: message\ndata: event2\n\n">>),
                Send(done)
            end,
            {stream, 200, [{<<"content-type">>, <<"text/event-stream">>}], StreamFun, State};
        trailers ->
            StreamFun = fun(Send) ->
                Send(<<"data">>),
                Send({done, [{<<"x-checksum">>, <<"abc123">>}]})
            end,
            {stream, 200, [{<<"content-type">>, <<"text/plain">>}], StreamFun, State};
        _ ->
            {reply, 404, [{<<"content-type">>, <<"text/plain">>}],
             <<"Not Found">>, State}
    end.

terminate(_Reason, _State) ->
    ok.
