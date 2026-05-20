%% @doc Example WebSocket echo service over HTTP/1.1.
%%
%%     {ok, Pid} = livery_example_ws:start(8081).
%%     %% connect a WebSocket client to ws://127.0.0.1:8081/
%%     %% every text/binary frame is echoed back.
%%     livery_example_ws:stop(Pid).
%%
%% The same handler also accepts WebSocket over H2/H3 when the
%% service is started with a TLS/QUIC listener and extended CONNECT
%% enabled.
-module(livery_example_ws).
-behaviour(ws_handler).

%% service
-export([start/0, start/1, stop/1, handler/1]).
%% ws_handler callbacks
-export([init/2, handle_in/2, handle_info/2, terminate/2]).

start() -> start(8081).

start(Port) ->
    livery:start_service(#{
        http    => #{port => Port},
        handler => fun ?MODULE:handler/1
    }).

stop(Pid) ->
    livery:stop_service(Pid).

handler(Req) ->
    livery_ws:upgrade(Req, ?MODULE, #{}).

%%====================================================================
%% ws_handler
%%====================================================================

init(_Req, _Opts) ->
    {ok, #{count => 0}}.

handle_in({text, Bin}, #{count := N} = State) ->
    {reply, [{text, Bin}], State#{count => N + 1}};
handle_in({binary, Bin}, #{count := N} = State) ->
    {reply, [{binary, Bin}], State#{count => N + 1}};
handle_in({ping, Bin}, State) ->
    {reply, [{pong, Bin}], State};
handle_in({close, Code, _Reason}, State) ->
    {stop, {closed, Code}, State};
handle_in(_Frame, State) ->
    {ok, State}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
