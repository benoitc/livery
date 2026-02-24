%% @doc Fast acceptor process.
%%
%% Simple process that blocks directly on accept - no gen_server overhead.
%% Each acceptor opens its own listen socket with SO_REUSEPORT enabled.
-module(livery_acceptor).

%% API
-export([start_link/1]).

%% Internal
-export([acceptor_loop/5]).

-spec start_link(map()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Opts) ->
    Port = maps:get(port, Opts),
    Handler = maps:get(handler, Opts),
    HandlerOpts = maps:get(handler_opts, Opts, []),
    SslOpts = maps:get(ssl_opts, Opts, []),
    Transport = case SslOpts of [] -> gen_tcp; _ -> ssl end,

    %% Open listen socket with SO_REUSEPORT
    case open_listen_socket(Port, Transport, SslOpts) of
        {ok, ListenSocket} ->
            Pid = proc_lib:spawn_link(?MODULE, acceptor_loop,
                                      [ListenSocket, Transport, Handler, HandlerOpts, SslOpts]),
            {ok, Pid};
        {error, Reason} ->
            {error, {listen_failed, Reason}}
    end.

%% @private Main acceptor loop - blocks on accept.
-spec acceptor_loop(gen_tcp:socket() | ssl:sslsocket(), gen_tcp | ssl,
                    module(), term(), list()) -> no_return().
acceptor_loop(ListenSocket, gen_tcp, Handler, HandlerOpts, _SslOpts) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            %% Spawn connection handler directly
            spawn_connection(Socket, gen_tcp, Handler, HandlerOpts, undefined),
            acceptor_loop(ListenSocket, gen_tcp, Handler, HandlerOpts, _SslOpts);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            acceptor_loop(ListenSocket, gen_tcp, Handler, HandlerOpts, _SslOpts)
    end;
acceptor_loop(ListenSocket, ssl, Handler, HandlerOpts, SslOpts) ->
    case ssl:transport_accept(ListenSocket) of
        {ok, TlsSocket} ->
            case ssl:handshake(TlsSocket, 5000) of
                {ok, SslSocket} ->
                    %% Check ALPN negotiated protocol
                    NegotiatedProto = case ssl:negotiated_protocol(SslSocket) of
                        {ok, <<"h2">>} -> h2;
                        {ok, <<"http/1.1">>} -> h1;
                        {error, protocol_not_negotiated} -> undefined
                    end,
                    spawn_connection(SslSocket, ssl, Handler, HandlerOpts, NegotiatedProto);
                {error, _Reason} ->
                    ssl:close(TlsSocket)
            end,
            acceptor_loop(ListenSocket, ssl, Handler, HandlerOpts, SslOpts);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            acceptor_loop(ListenSocket, ssl, Handler, HandlerOpts, SslOpts)
    end.

%% @private Spawn connection handler and transfer socket ownership.
spawn_connection(Socket, Transport, Handler, HandlerOpts, NegotiatedProto) ->
    case livery_connection:start_link(Socket, Transport, Handler, HandlerOpts, NegotiatedProto) of
        {ok, Pid} ->
            case Transport of
                gen_tcp -> gen_tcp:controlling_process(Socket, Pid);
                ssl -> ssl:controlling_process(Socket, Pid)
            end,
            Pid ! activate_socket,
            ok;
        {error, _Reason} ->
            case Transport of
                gen_tcp -> gen_tcp:close(Socket);
                ssl -> ssl:close(Socket)
            end
    end.

%% @private Open listen socket with SO_REUSEPORT.
open_listen_socket(Port, gen_tcp, _SslOpts) ->
    TcpOpts = [
        binary,
        {active, false},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, 1024},
        {packet, raw}
    ] ++ reuseport_opts(),
    gen_tcp:listen(Port, TcpOpts);
open_listen_socket(Port, ssl, SslOpts) ->
    TcpOpts = [
        binary,
        {active, false},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, 1024},
        {packet, raw}
    ] ++ reuseport_opts(),
    %% Add ALPN for HTTP/2 and HTTP/1.1 negotiation
    AlpnOpts = [{alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}],
    ssl:listen(Port, TcpOpts ++ AlpnOpts ++ SslOpts).

%% @private SO_REUSEPORT options per platform.
reuseport_opts() ->
    case os:type() of
        {unix, linux} ->
            [{raw, 1, 15, <<1:32/native>>}];
        {unix, darwin} ->
            [{raw, 16#ffff, 16#0200, <<1:32/native>>}];
        {unix, freebsd} ->
            [{raw, 16#ffff, 16#0200, <<1:32/native>>}];
        _ ->
            []
    end.
