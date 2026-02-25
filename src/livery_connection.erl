%% @doc Fast connection handler process.
%%
%% Plain process implementation for maximum performance.
%% No gen_statem overhead - direct receive loop.
-module(livery_connection).

-include("livery.hrl").

%% API
-export([start/5, start_link/5]).

%% Internal
-export([init/6]).

%% HTTP/2 SETTINGS timeout
-define(SETTINGS_TIMEOUT, 5000).

%% HTTP/2 connection preface
-define(H2_PREFACE, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>).
-define(H2_PREFACE_SIZE, 24).

-record(state, {
    socket :: gen_tcp:socket() | ssl:sslsocket(),
    transport :: gen_tcp | ssl,
    handler :: module(),
    handler_opts :: term(),
    protocol :: h1 | h2 | undefined,
    protocol_state :: term(),
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    request_timeout :: timeout(),
    idle_timeout :: timeout()
}).

%% API

-spec start(term(), term(), module(), term(), term()) -> {ok, pid()} | {error, term()}.
start(Socket, Transport, Handler, HandlerOpts, NegotiatedProto) ->
    Pid = proc_lib:spawn(?MODULE, init, [self(), Socket, Transport, Handler, HandlerOpts, NegotiatedProto]),
    {ok, Pid}.

-spec start_link(term(), term(), module(), term(), term()) -> {ok, pid()} | {error, term()}.
start_link(Socket, Transport, Handler, HandlerOpts, NegotiatedProto) ->
    Pid = proc_lib:spawn_link(?MODULE, init, [self(), Socket, Transport, Handler, HandlerOpts, NegotiatedProto]),
    {ok, Pid}.

%% @private Initialize connection process.
-spec init(pid(), term(), term(), module(), term(), term()) -> ok | no_return().
init(_Parent, Socket, Transport, Handler, HandlerOpts, NegotiatedProto) ->
    RequestTimeout = application:get_env(livery, request_timeout, 60000),
    IdleTimeout = application:get_env(livery, idle_timeout, 300000),

    State = #state{
        socket = Socket,
        transport = Transport,
        handler = Handler,
        handler_opts = HandlerOpts,
        protocol = undefined,
        protocol_state = undefined,
        peer = undefined,
        request_timeout = RequestTimeout,
        idle_timeout = IdleTimeout
    },

    %% Wait for socket activation message
    receive
        activate_socket ->
            activate(State, Transport, NegotiatedProto)
    after 5000 ->
        close_socket(Socket, Transport)
    end.

%% Activate socket after ownership transfer
activate(State, {ssl_pending, SslOpts}, _NegotiatedProto) ->
    Socket = State#state.socket,
    Handler = State#state.handler,
    HandlerOpts = State#state.handler_opts,

    %% Perform TLS handshake
    case ssl:handshake(Socket, SslOpts, 5000) of
        {ok, SslSocket} ->
            {Protocol, ProtocolState} = case ssl:negotiated_protocol(SslSocket) of
                {ok, <<"h2">>} ->
                    {h2, livery_h2:init(#{handler => Handler, handler_opts => HandlerOpts})};
                {ok, <<"http/1.1">>} ->
                    {h1, livery_h1:init(Handler, HandlerOpts)};
                {error, protocol_not_negotiated} ->
                    {undefined, undefined}
            end,
            Peer = case ssl:peername(SslSocket) of {ok, P} -> P; _ -> undefined end,
            ssl:setopts(SslSocket, [{active, once}]),

            NewState = State#state{
                socket = SslSocket,
                transport = ssl,
                peer = Peer,
                protocol = Protocol,
                protocol_state = ProtocolState
            },

            case Protocol of
                undefined ->
                    detect_loop(NewState, <<>>);
                h2 ->
                    connection_loop(NewState);
                h1 ->
                    connection_loop(NewState)
            end;
        {error, _Reason} ->
            ssl:close(Socket)
    end;

activate(State, gen_tcp, _NegotiatedProto) ->
    Socket = State#state.socket,

    Peer = case inet:peername(Socket) of {ok, P} -> P; _ -> undefined end,
    inet:setopts(Socket, [{active, once}]),

    %% Plain TCP - detect protocol (support HTTP/2 prior knowledge)
    NewState = State#state{peer = Peer},
    detect_loop(NewState, <<>>);

activate(State, ssl, NegotiatedProto) ->
    Socket = State#state.socket,
    Handler = State#state.handler,
    HandlerOpts = State#state.handler_opts,

    Peer = case ssl:peername(Socket) of {ok, P} -> P; _ -> undefined end,
    ssl:setopts(Socket, [{active, once}]),

    case NegotiatedProto of
        h2 ->
            ProtocolState = livery_h2:init(#{handler => Handler, handler_opts => HandlerOpts}),
            connection_loop(State#state{peer = Peer, protocol = h2, protocol_state = ProtocolState});
        h1 ->
            ProtocolState = livery_h1:init(Handler, HandlerOpts),
            connection_loop(State#state{peer = Peer, protocol = h1, protocol_state = ProtocolState});
        undefined ->
            detect_loop(State#state{peer = Peer}, <<>>)
    end.

%% Protocol detection loop (for SSL without ALPN)
detect_loop(#state{socket = Socket, transport = Transport} = State, Buffer) ->
    receive
        {tcp, Socket, Data} ->
            detect_protocol(State, <<Buffer/binary, Data/binary>>);
        {ssl, Socket, Data} ->
            detect_protocol(State, <<Buffer/binary, Data/binary>>);
        {tcp_closed, Socket} ->
            ok;
        {ssl_closed, Socket} ->
            ok;
        {tcp_error, Socket, _Reason} ->
            close_socket(Socket, Transport);
        {ssl_error, Socket, _Reason} ->
            close_socket(Socket, Transport)
    after 5000 ->
        %% Detection timeout - assume HTTP/1.1
        Handler = State#state.handler,
        HandlerOpts = State#state.handler_opts,
        ProtocolState = livery_h1:init(Handler, HandlerOpts),
        NewState = State#state{protocol = h1, protocol_state = ProtocolState},
        case byte_size(Buffer) of
            0 -> connection_loop(NewState);
            _ -> handle_h1_data(Buffer, NewState)
        end
    end.

detect_protocol(State, Buffer) when byte_size(Buffer) >= ?H2_PREFACE_SIZE ->
    <<Preface:?H2_PREFACE_SIZE/binary, _Rest/binary>> = Buffer,
    Handler = State#state.handler,
    HandlerOpts = State#state.handler_opts,

    case Preface =:= ?H2_PREFACE of
        true ->
            ProtocolState = livery_h2:init(#{handler => Handler, handler_opts => HandlerOpts}),
            NewState = State#state{protocol = h2, protocol_state = ProtocolState},
            handle_h2_data(Buffer, NewState);
        false ->
            ProtocolState = livery_h1:init(Handler, HandlerOpts),
            NewState = State#state{protocol = h1, protocol_state = ProtocolState},
            handle_h1_data(Buffer, NewState)
    end;
detect_protocol(State, Buffer) ->
    %% Need more data - check if could still be H2
    PrefacePrefix = binary:part(?H2_PREFACE, 0, byte_size(Buffer)),
    case Buffer =:= PrefacePrefix of
        true ->
            %% Could still be H2, wait for more
            set_active(State),
            detect_loop(State, Buffer);
        false ->
            %% Not H2, use H1
            Handler = State#state.handler,
            HandlerOpts = State#state.handler_opts,
            ProtocolState = livery_h1:init(Handler, HandlerOpts),
            NewState = State#state{protocol = h1, protocol_state = ProtocolState},
            handle_h1_data(Buffer, NewState)
    end.

%% Main connection loop
connection_loop(#state{socket = Socket, protocol = h2,
                        protocol_state = ProtocolState, transport = Transport,
                        idle_timeout = IdleTimeout} = State) ->
    %% For H2, use the minimum of idle timeout and SETTINGS_ACK timeout
    SettingsTimeout = livery_h2:settings_ack_timeout(ProtocolState),
    Timeout = case SettingsTimeout of
        infinity -> IdleTimeout;
        T -> min(T, IdleTimeout)
    end,
    receive
        {tcp, Socket, Data} ->
            handle_data(h2, Data, State);
        {ssl, Socket, Data} ->
            handle_data(h2, Data, State);
        {tcp_closed, Socket} ->
            terminate(State);
        {ssl_closed, Socket} ->
            terminate(State);
        {tcp_error, Socket, _Reason} ->
            terminate(State);
        {ssl_error, Socket, _Reason} ->
            terminate(State)
    after Timeout ->
        %% Check if this is a settings timeout or idle timeout
        case livery_h2:check_settings_timeout(ProtocolState) of
            timeout ->
                %% SETTINGS_ACK timeout per RFC 7540 Section 6.5
                GoawayFrame = livery_h2:close(4, ProtocolState), %% SETTINGS_TIMEOUT
                send_data(Socket, Transport, GoawayFrame),
                terminate(State);
            ok ->
                %% Idle timeout
                terminate(State)
        end
    end;
connection_loop(#state{socket = Socket, protocol = Protocol,
                        idle_timeout = IdleTimeout} = State) ->
    receive
        {tcp, Socket, Data} ->
            handle_data(Protocol, Data, State);
        {ssl, Socket, Data} ->
            handle_data(Protocol, Data, State);
        {tcp_closed, Socket} ->
            terminate(State);
        {ssl_closed, Socket} ->
            terminate(State);
        {tcp_error, Socket, _Reason} ->
            terminate(State);
        {ssl_error, Socket, _Reason} ->
            terminate(State)
    after IdleTimeout ->
        terminate(State)
    end.

handle_data(h1, Data, State) ->
    handle_h1_data(Data, State);
handle_data(h2, Data, State) ->
    handle_h2_data(Data, State).

%% HTTP/1.1 data handling
handle_h1_data(Data, #state{socket = Socket, transport = Transport,
                             protocol_state = ProtocolState} = State) ->
    case livery_h1:handle_data(Data, ProtocolState) of
        {ok, NewProtocolState} ->
            set_active(State),
            connection_loop(State#state{protocol_state = NewProtocolState});

        {continue, NewProtocolState} ->
            ContinueResponse = <<"HTTP/1.1 100 Continue\r\n\r\n">>,
            case send_data(Socket, Transport, ContinueResponse) of
                ok ->
                    NextProtocolState = livery_h1:continue_sent(NewProtocolState),
                    set_active(State),
                    connection_loop(State#state{protocol_state = NextProtocolState});
                {error, _} ->
                    terminate(State#state{protocol_state = NewProtocolState})
            end;

        {response, Status, Headers, Body, NewProtocolState} ->
            case livery_h1:send_response(Socket, Status, Headers, Body, NewProtocolState) of
                {ok, NextProtocolState} ->
                    set_active(State),
                    connection_loop(State#state{protocol_state = NextProtocolState});
                {close, _} ->
                    terminate(State#state{protocol_state = NewProtocolState})
            end;

        {stream, Status, Headers, StreamFun, NewProtocolState} ->
            case livery_h1:send_stream(Socket, Status, Headers, StreamFun, NewProtocolState) of
                {ok, NextProtocolState} ->
                    set_active(State),
                    connection_loop(State#state{protocol_state = NextProtocolState});
                {close, _} ->
                    terminate(State#state{protocol_state = NewProtocolState})
            end;

        {close, _NewProtocolState} ->
            terminate(State);

        {error, _Reason, NewProtocolState} ->
            send_error_response(400, State),
            terminate(State#state{protocol_state = NewProtocolState})
    end.

%% HTTP/2 data handling
%% Optimized to batch all response frames and send in a single syscall
handle_h2_data(Data, #state{socket = Socket, transport = Transport,
                             handler = Handler, handler_opts = HandlerOpts,
                             peer = Peer, protocol_state = ProtocolState} = State) ->
    case livery_h2:handle_data(Data, ProtocolState) of
        {ok, Responses, NewProtocolState} ->
            case process_h2_responses(Responses, Handler, HandlerOpts, Peer,
                                       NewProtocolState, []) of
                {ok, FrameAcc, FinalProtocolState} ->
                    %% Send all batched frames in one syscall
                    case send_h2_batch(FrameAcc, Socket, Transport) of
                        ok ->
                            set_active(State),
                            connection_loop(State#state{protocol_state = FinalProtocolState});
                        {error, _Reason} ->
                            terminate(State#state{protocol_state = FinalProtocolState})
                    end;
                {stream, StreamId, Status, Headers, StreamFun, FrameAcc, FinalProtocolState} ->
                    %% Flush batched frames, then handle streaming response
                    case send_h2_batch(FrameAcc, Socket, Transport) of
                        ok ->
                            case handle_h2_stream_response(StreamId, Status, Headers, StreamFun,
                                                           Socket, Transport, FinalProtocolState) of
                                {ok, StreamState} ->
                                    set_active(State),
                                    connection_loop(State#state{protocol_state = StreamState});
                                {error, _Reason, StreamState} ->
                                    GoawayFrame = livery_h2:close(1, StreamState),
                                    send_data(Socket, Transport, GoawayFrame),
                                    terminate(State#state{protocol_state = StreamState})
                            end;
                        {error, _Reason} ->
                            terminate(State#state{protocol_state = FinalProtocolState})
                    end;
                {error, _Reason, FinalProtocolState} ->
                    GoawayFrame = livery_h2:close(1, FinalProtocolState),
                    send_data(Socket, Transport, GoawayFrame),
                    terminate(State#state{protocol_state = FinalProtocolState})
            end;

        {error, Reason, NewProtocolState} ->
            GoawayFrame = livery_h2:close(h2_error_code(Reason), NewProtocolState),
            send_data(Socket, Transport, GoawayFrame),
            terminate(State#state{protocol_state = NewProtocolState})
    end.

%% Send batched H2 frames in one syscall
send_h2_batch([], _Socket, _Transport) ->
    ok;
send_h2_batch(FrameAcc, Socket, Transport) ->
    send_data(Socket, Transport, lists:reverse(FrameAcc)).

%% Process HTTP/2 responses - accumulates frames instead of sending immediately
process_h2_responses([], _Handler, _HandlerOpts, _Peer, State, FrameAcc) ->
    {ok, FrameAcc, State};
process_h2_responses([settings_acked | Rest], Handler, HandlerOpts, Peer, State, FrameAcc) ->
    process_h2_responses(Rest, Handler, HandlerOpts, Peer, State, FrameAcc);
process_h2_responses([{send, IoData} | Rest], Handler, HandlerOpts, Peer, State, FrameAcc) ->
    %% Accumulate frame instead of sending
    process_h2_responses(Rest, Handler, HandlerOpts, Peer, State, [IoData | FrameAcc]);
process_h2_responses([{request, StreamId, H2Request} | Rest], Handler, HandlerOpts, Peer, State, FrameAcc) ->
    case handle_h2_request(StreamId, H2Request, Handler, HandlerOpts, Peer, State) of
        {ok, ResponseFrames, NewState} ->
            %% Accumulate response frames
            process_h2_responses(Rest, Handler, HandlerOpts, Peer, NewState, [ResponseFrames | FrameAcc]);
        {stream, Status, Headers, StreamFun, NewState} ->
            %% Streaming response - need to flush and handle specially
            {stream, StreamId, Status, Headers, StreamFun, FrameAcc, NewState};
        {error, Reason, NewState} ->
            {error, Reason, NewState}
    end;
process_h2_responses([{http_error, StreamId, Status} | Rest], Handler, HandlerOpts, Peer, State, FrameAcc) ->
    {ResponseFrames, NewState} = make_h2_error_response(StreamId, Status, State),
    process_h2_responses(Rest, Handler, HandlerOpts, Peer, NewState, [ResponseFrames | FrameAcc]);
process_h2_responses([_ | Rest], Handler, HandlerOpts, Peer, State, FrameAcc) ->
    %% Skip unknown response types
    process_h2_responses(Rest, Handler, HandlerOpts, Peer, State, FrameAcc).

%% Handle an HTTP/2 request - returns frames instead of sending
handle_h2_request(StreamId, H2Request, Handler, HandlerOpts, Peer, State) ->
    Req = livery_h2:request_to_livery_req(H2Request, Handler, HandlerOpts, Peer),
    try
        case Handler:init(Req, HandlerOpts) of
            {ok, Req1, HandlerState} ->
                case Handler:handle(Req1, HandlerState) of
                    {reply, Status, Headers, Body, _NewHandlerState} ->
                        {ok, ResponseFrames, NewState} =
                            livery_h2:send_response(StreamId, Status, Headers, Body, State),
                        {ok, ResponseFrames, NewState};
                    {stream, Status, Headers, StreamFun, _NewHandlerState} ->
                        %% Streaming needs special handling - return marker
                        {stream, Status, Headers, StreamFun, State};
                    _ ->
                        make_h2_error_result(StreamId, 500, State)
                end;
            {error, _Reason} ->
                make_h2_error_result(StreamId, 500, State)
        end
    catch
        _:_ ->
            make_h2_error_result(StreamId, 500, State)
    end.

%% Helper to create error response result
make_h2_error_result(StreamId, Status, State) ->
    {ResponseFrames, NewState} = make_h2_error_response(StreamId, Status, State),
    {ok, ResponseFrames, NewState}.

%% Make error response frames (doesn't send)
make_h2_error_response(StreamId, Status, State) ->
    Body = livery_resp:status_text(Status),
    Headers = [{<<"content-type">>, <<"text/plain">>}],
    {ok, ResponseFrames, NewState} = livery_h2:send_response(StreamId, Status, Headers, Body, State),
    {ResponseFrames, NewState}.

handle_h2_stream_response(StreamId, Status, Headers, StreamFun, Socket, Transport, State) ->
    {ok, HeaderFrames, State1} = livery_h2:send_response(StreamId, Status, Headers, <<>>, State),
    case send_data(Socket, Transport, HeaderFrames) of
        ok ->
            stream_h2_chunks(StreamId, StreamFun, Socket, Transport, State1);
        {error, Reason} ->
            {error, Reason, State1}
    end.

stream_h2_chunks(StreamId, StreamFun, Socket, Transport, State) ->
    StateRef = make_ref(),
    put(StateRef, {State, ok}),

    SendFun = fun
        (done) ->
            {CurrentState, _} = get(StateRef),
            {ok, DataFrame, NewState} = livery_h2:send_stream_end(StreamId, CurrentState),
            case send_data(Socket, Transport, DataFrame) of
                ok -> put(StateRef, {NewState, ok});
                {error, R} -> put(StateRef, {NewState, {error, R}})
            end,
            ok;
        ({done, Trailers}) ->
            {CurrentState, _} = get(StateRef),
            {ok, TrailerFrames, NewState} = livery_h2:send_trailers(StreamId, Trailers, CurrentState),
            case send_data(Socket, Transport, TrailerFrames) of
                ok -> put(StateRef, {NewState, ok});
                {error, R} -> put(StateRef, {NewState, {error, R}})
            end,
            ok;
        (Chunk) ->
            {CurrentState, _} = get(StateRef),
            case livery_h2:send_stream_data(StreamId, Chunk, false, CurrentState) of
                {ok, DataFrame, NewState} ->
                    case send_data(Socket, Transport, DataFrame) of
                        ok -> put(StateRef, {NewState, ok});
                        {error, R} -> put(StateRef, {NewState, {error, R}})
                    end;
                {buffered, _, NewState} ->
                    put(StateRef, {NewState, ok})
            end,
            ok
    end,

    try
        StreamFun(SendFun),
        {FinalState, FinalStatus} = get(StateRef),
        erase(StateRef),
        case FinalStatus of
            ok -> {ok, FinalState};
            {error, Reason} -> {error, Reason, FinalState}
        end
    catch
        _:_ ->
            {FinalState2, _} = get(StateRef),
            erase(StateRef),
            {ok, FinalState2}
    end.

%% Helpers
set_active(#state{socket = Socket, transport = gen_tcp}) ->
    inet:setopts(Socket, [{active, once}]);
set_active(#state{socket = Socket, transport = ssl}) ->
    ssl:setopts(Socket, [{active, once}]).

send_data(Socket, gen_tcp, Data) ->
    gen_tcp:send(Socket, Data);
send_data(Socket, ssl, Data) ->
    ssl:send(Socket, Data).

close_socket(Socket, gen_tcp) ->
    gen_tcp:close(Socket);
close_socket(Socket, ssl) ->
    ssl:close(Socket);
close_socket(Socket, {ssl_pending, _}) ->
    ssl:close(Socket).

send_error_response(Status, #state{socket = Socket, transport = Transport}) ->
    Body = livery_resp:status_text(Status),
    Response = livery_resp:build(Status, [{<<"content-type">>, <<"text/plain">>}], Body, {1, 1}),
    send_data(Socket, Transport, Response).

terminate(#state{socket = Socket, transport = Transport, protocol = h2,
                  protocol_state = ProtocolState}) when ProtocolState =/= undefined ->
    GoawayFrame = livery_h2:close(0, ProtocolState),
    send_data(Socket, Transport, GoawayFrame),
    close_socket(Socket, Transport);
terminate(#state{socket = Socket, transport = Transport, protocol = h1,
                  protocol_state = ProtocolState}) when ProtocolState =/= undefined ->
    livery_h1:close(ProtocolState),
    close_socket(Socket, Transport);
terminate(#state{socket = Socket, transport = Transport}) ->
    close_socket(Socket, Transport).

h2_error_code({protocol_error, _}) -> 1;
h2_error_code(protocol_error) -> 1;
h2_error_code({compression_error, _}) -> 9;
h2_error_code(flow_control_error) -> 3;
h2_error_code({goaway, _, ErrorCode}) -> ErrorCode;
h2_error_code(_) -> 0.
