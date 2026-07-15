%% @doc Server-side `ws_handler' used by livery_ws_SUITE.
%%
%% On connect it emits a single text frame carrying the client peer it
%% saw in the handshake `Req' (`peer:Ip:Port', or `peer:undefined'), so a
%% test can assert the adapter surfaced the peer address to the handler.
-module(livery_ws_probe_handler).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(Req, _Opts) ->
    {reply, [{text, format_peer(maps:get(peer, Req, undefined))}], undefined}.

handle_in(_Frame, State) ->
    {ok, State}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

format_peer({Ip, Port}) ->
    iolist_to_binary([
        <<"peer:">>,
        inet:ntoa(Ip),
        <<":">>,
        integer_to_binary(Port)
    ]);
format_peer(undefined) ->
    <<"peer:undefined">>.
