%% @doc Server-side WebTransport echo handler for the Livery e2e suite.
%%
%% Implements the `webtransport_handler' behaviour: echoes stream data
%% back on FIN (bidi) and echoes datagrams.
-module(livery_wt_echo_handler).
-behaviour(webtransport_handler).

-export([
    init/3,
    handle_stream/4,
    handle_stream_fin/4,
    handle_datagram/2,
    handle_stream_closed/3,
    terminate/2
]).

-record(state, {session, streams = #{}}).

init(Session, _Request, _Opts) ->
    {ok, #state{session = Session}}.

handle_stream(StreamId, Type, Data, #state{streams = Streams} = State) ->
    Existing = maps:get(StreamId, Streams, <<>>),
    State1 = State#state{streams = Streams#{StreamId => <<Existing/binary, Data/binary>>}},
    case Type of
        bidi when Data =/= <<>> -> {ok, State1, [{send, StreamId, Data}]};
        _ -> {ok, State1}
    end.

handle_stream_fin(StreamId, Type, Data, #state{streams = Streams} = State) ->
    Existing = maps:get(StreamId, Streams, <<>>),
    AllData = <<Existing/binary, Data/binary>>,
    State1 = State#state{streams = maps:remove(StreamId, Streams)},
    case Type of
        bidi -> {ok, State1, [{send, StreamId, AllData, fin}]};
        uni -> {ok, State1}
    end.

handle_datagram(Data, State) ->
    {ok, State, [{send_datagram, Data}]}.

handle_stream_closed(_StreamId, _Reason, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
