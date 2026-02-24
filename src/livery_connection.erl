%% @doc Connection handler process.
%%
%% One process per connection, manages the lifecycle of a connection
%% and delegates to the appropriate protocol handler.
-module(livery_connection).

-behaviour(gen_statem).

-include("livery.hrl").

%% API
-export([start_link/5]).

%% gen_statem callbacks
-export([
    callback_mode/0,
    init/1,
    activating/3,
    detecting/3,
    waiting/3,
    active/3,
    terminate/3
]).

-record(state, {
    socket :: gen_tcp:socket() | ssl:sslsocket(),
    transport :: gen_tcp | ssl,
    handler :: module(),
    handler_opts :: term(),
    protocol :: h1 | h2 | h3 | undefined,
    protocol_state :: livery_h1:state() | livery_h2:state() | term() | undefined,
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    request_timeout :: timeout(),
    idle_timeout :: timeout(),
    timer_ref :: reference() | undefined,
    settings_timer_ref :: reference() | undefined,  %% HTTP/2 SETTINGS_ACK timeout
    detect_buffer = <<>> :: binary()  %% Buffer for protocol preface detection
}).

%% HTTP/2 SETTINGS_TIMEOUT (RFC 7540 recommends reasonable timeout)
-define(SETTINGS_TIMEOUT, 5000).

%% HTTP/2 connection preface
-define(H2_PREFACE, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>).
-define(H2_PREFACE_SIZE, 24).

%% API

-spec start_link(gen_tcp:socket() | ssl:sslsocket(), gen_tcp | ssl, module(), term(),
                 h1 | h2 | undefined) -> {ok, pid()} | {error, term()}.
start_link(Socket, Transport, Handler, HandlerOpts, NegotiatedProto) ->
    gen_statem:start_link(?MODULE, {Socket, Transport, Handler, HandlerOpts, NegotiatedProto}, []).

%% gen_statem callbacks

-spec callback_mode() -> state_functions.
callback_mode() ->
    state_functions.

-spec init({gen_tcp:socket() | ssl:sslsocket(), gen_tcp | ssl, module(), term(),
             h1 | h2 | undefined}) -> gen_statem:init_result(activating).
init({Socket, Transport, Handler, HandlerOpts, NegotiatedProto}) ->
    %% Get timeouts from application config
    RequestTimeout = application:get_env(livery, request_timeout, 60000),
    IdleTimeout = application:get_env(livery, idle_timeout, 300000),

    %% Initialize protocol state based on negotiated protocol
    {Protocol, ProtocolState} = init_protocol(NegotiatedProto, Handler, HandlerOpts),

    State = #state{
        socket = Socket,
        transport = Transport,
        handler = Handler,
        handler_opts = HandlerOpts,
        protocol = Protocol,
        protocol_state = ProtocolState,
        peer = undefined,
        request_timeout = RequestTimeout,
        idle_timeout = IdleTimeout
    },

    %% Acceptor will send activate_socket message after transferring ownership
    %% Set a timeout in case activate message never arrives
    {ok, activating, State, [{state_timeout, 5000, activate_timeout}]}.

%% Initialize protocol based on ALPN negotiation result
init_protocol(h1, Handler, HandlerOpts) ->
    {h1, livery_h1:init(Handler, HandlerOpts)};
init_protocol(h2, Handler, HandlerOpts) ->
    {h2, livery_h2:init(#{handler => Handler, handler_opts => HandlerOpts})};
init_protocol(undefined, _Handler, _HandlerOpts) ->
    %% Protocol not negotiated - will detect via preface
    {undefined, undefined}.

%% Activating - waiting for socket ownership before activating
-spec activating(gen_statem:event_type(), term(), #state{}) ->
    gen_statem:event_handler_result(atom()).
activating(info, activate_socket, #state{socket = Socket, transport = Transport,
                                          protocol = Protocol,
                                          idle_timeout = IdleTimeout} = State) ->
    %% Now we have ownership - get peer info and activate socket
    Peer = case get_peername(Socket, Transport) of
        {ok, P} -> P;
        _ -> undefined
    end,
    case set_active(Socket, Transport) of
        ok ->
            case Protocol of
                undefined ->
                    %% Protocol not negotiated - need to detect via preface
                    TimerRef = erlang:start_timer(5000, self(), detect_timeout),
                    {next_state, detecting, State#state{peer = Peer, timer_ref = TimerRef}};
                _ ->
                    %% Protocol already known from ALPN
                    TimerRef = erlang:start_timer(IdleTimeout, self(), idle_timeout),
                    {next_state, waiting, State#state{peer = Peer, timer_ref = TimerRef}}
            end;
        {error, _Reason} ->
            {stop, normal, State}
    end;
activating(info, {tcp_closed, _}, State) ->
    {stop, normal, State};
activating(info, {ssl_closed, _}, State) ->
    {stop, normal, State};
activating(state_timeout, activate_timeout, State) ->
    %% Didn't receive activate message in time, close
    {stop, normal, State};
activating(EventType, Event, State) ->
    handle_common(EventType, Event, State).

%% Detecting protocol via connection preface
-spec detecting(gen_statem:event_type(), term(), #state{}) ->
    gen_statem:event_handler_result(atom()).
detecting(info, {tcp, Socket, Data}, #state{socket = Socket} = State) ->
    detect_protocol(Data, State);
detecting(info, {ssl, Socket, Data}, #state{socket = Socket} = State) ->
    detect_protocol(Data, State);
detecting(info, {tcp_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, normal, State};
detecting(info, {ssl_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, normal, State};
detecting(info, {tcp_error, Socket, Reason}, #state{socket = Socket} = State) ->
    {stop, {error, Reason}, State};
detecting(info, {ssl_error, Socket, Reason}, #state{socket = Socket} = State) ->
    {stop, {error, Reason}, State};
detecting(info, {timeout, TimerRef, detect_timeout}, #state{timer_ref = TimerRef,
                                                             detect_buffer = Buffer,
                                                             handler = Handler,
                                                             handler_opts = HandlerOpts,
                                                             idle_timeout = IdleTimeout} = State) ->
    %% Detection timeout - assume HTTP/1.1
    cancel_timer(TimerRef),
    ProtocolState = livery_h1:init(Handler, HandlerOpts),
    NewState = State#state{
        protocol = h1,
        protocol_state = ProtocolState,
        timer_ref = undefined,
        detect_buffer = <<>>
    },
    %% Process any buffered data
    case byte_size(Buffer) of
        0 ->
            TimerRef1 = erlang:start_timer(IdleTimeout, self(), idle_timeout),
            {next_state, waiting, NewState#state{timer_ref = TimerRef1}};
        _ ->
            handle_data(Buffer, NewState)
    end;
detecting(EventType, Event, State) ->
    handle_common(EventType, Event, State).

%% Waiting for data
-spec waiting(gen_statem:event_type(), term(), #state{}) ->
    gen_statem:event_handler_result(atom()).
waiting(info, {tcp, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(Data, State);
waiting(info, {ssl, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(Data, State);
waiting(info, {tcp_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, normal, State};
waiting(info, {ssl_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, normal, State};
waiting(info, {tcp_error, Socket, Reason}, #state{socket = Socket} = State) ->
    {stop, {error, Reason}, State};
waiting(info, {ssl_error, Socket, Reason}, #state{socket = Socket} = State) ->
    {stop, {error, Reason}, State};
waiting(info, {timeout, TimerRef, idle_timeout}, #state{timer_ref = TimerRef} = State) ->
    {stop, {shutdown, idle_timeout}, State};
waiting(info, {timeout, TimerRef, settings_timeout},
        #state{settings_timer_ref = TimerRef, protocol = h2,
               socket = Socket, transport = Transport,
               protocol_state = ProtocolState} = State) ->
    %% SETTINGS_TIMEOUT - peer didn't acknowledge our SETTINGS in time
    %% Send GOAWAY with SETTINGS_TIMEOUT error code (0x4)
    GoawayFrame = livery_h2:close(4, ProtocolState),  %% SETTINGS_TIMEOUT = 4
    send_data(Socket, Transport, GoawayFrame),
    {stop, {shutdown, settings_timeout}, State#state{settings_timer_ref = undefined}};
waiting(EventType, Event, State) ->
    handle_common(EventType, Event, State).

%% Active (processing request)
-spec active(gen_statem:event_type(), term(), #state{}) ->
    gen_statem:event_handler_result(atom()).
active(info, {tcp, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(Data, State);
active(info, {ssl, Socket, Data}, #state{socket = Socket} = State) ->
    handle_data(Data, State);
active(info, {tcp_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, normal, State};
active(info, {ssl_closed, Socket}, #state{socket = Socket} = State) ->
    {stop, normal, State};
active(info, {tcp_error, Socket, Reason}, #state{socket = Socket} = State) ->
    {stop, {error, Reason}, State};
active(info, {timeout, TimerRef, settings_timeout},
       #state{settings_timer_ref = TimerRef, protocol = h2,
              socket = Socket, transport = Transport,
              protocol_state = ProtocolState} = State) ->
    %% SETTINGS_TIMEOUT - peer didn't acknowledge our SETTINGS in time
    GoawayFrame = livery_h2:close(4, ProtocolState),  %% SETTINGS_TIMEOUT = 4
    send_data(Socket, Transport, GoawayFrame),
    {stop, {shutdown, settings_timeout}, State#state{settings_timer_ref = undefined}};
active(info, {ssl_error, Socket, Reason}, #state{socket = Socket} = State) ->
    {stop, {error, Reason}, State};
active(info, {timeout, TimerRef, request_timeout}, #state{timer_ref = TimerRef} = State) ->
    send_error_response(408, State),
    {stop, {shutdown, request_timeout}, State};
active(EventType, Event, State) ->
    handle_common(EventType, Event, State).

-spec terminate(term(), atom(), #state{}) -> ok.
terminate(_Reason, _StateName, #state{protocol = h1, protocol_state = ProtocolState,
                                       socket = Socket, transport = Transport}) ->
    livery_h1:close(ProtocolState),
    Transport:close(Socket),
    ok;
terminate(_Reason, _StateName, #state{protocol = h2, protocol_state = ProtocolState,
                                       socket = Socket, transport = Transport})
  when ProtocolState =/= undefined ->
    %% Send GOAWAY with NO_ERROR before closing
    GoawayFrame = livery_h2:close(0, ProtocolState),
    send_data(Socket, Transport, GoawayFrame),
    Transport:close(Socket),
    ok;
terminate(_Reason, _StateName, #state{socket = Socket, transport = Transport}) ->
    Transport:close(Socket),
    ok.

%% Internal functions

handle_common(_EventType, _Event, State) ->
    {keep_state, State}.

%% Protocol detection via connection preface
detect_protocol(Data, #state{detect_buffer = Buffer, socket = Socket, transport = Transport,
                              handler = Handler, handler_opts = HandlerOpts,
                              timer_ref = TimerRef} = State) ->
    NewBuffer = <<Buffer/binary, Data/binary>>,

    case byte_size(NewBuffer) >= ?H2_PREFACE_SIZE of
        true ->
            %% We have enough data to check for H2 preface
            <<Preface:?H2_PREFACE_SIZE/binary, _Rest/binary>> = NewBuffer,
            cancel_timer(TimerRef),
            case Preface =:= ?H2_PREFACE of
                true ->
                    %% HTTP/2 connection
                    ProtocolState = livery_h2:init(#{handler => Handler, handler_opts => HandlerOpts}),
                    %% Start SETTINGS_TIMEOUT timer per RFC 7540
                    SettingsTimerRef = erlang:start_timer(?SETTINGS_TIMEOUT, self(), settings_timeout),
                    NewState = State#state{
                        protocol = h2,
                        protocol_state = ProtocolState,
                        detect_buffer = <<>>,
                        timer_ref = undefined,
                        settings_timer_ref = SettingsTimerRef
                    },
                    %% Process preface and any remaining data through H2
                    handle_data(NewBuffer, NewState);
                false ->
                    %% Not HTTP/2 - assume HTTP/1.1
                    ProtocolState = livery_h1:init(Handler, HandlerOpts),
                    NewState = State#state{
                        protocol = h1,
                        protocol_state = ProtocolState,
                        detect_buffer = <<>>,
                        timer_ref = undefined
                    },
                    %% Process all buffered data as HTTP/1.1
                    handle_data(NewBuffer, NewState)
            end;
        false ->
            %% Need more data - check if first bytes rule out H2
            case can_be_h2_preface(NewBuffer) of
                true ->
                    %% Could still be H2 preface, wait for more data
                    ok = set_active(Socket, Transport),
                    {keep_state, State#state{detect_buffer = NewBuffer}};
                false ->
                    %% Definitely not H2 - use H1
                    cancel_timer(TimerRef),
                    ProtocolState = livery_h1:init(Handler, HandlerOpts),
                    NewState = State#state{
                        protocol = h1,
                        protocol_state = ProtocolState,
                        detect_buffer = <<>>,
                        timer_ref = undefined
                    },
                    handle_data(NewBuffer, NewState)
            end
    end.

%% Check if buffer could still be start of H2 preface
can_be_h2_preface(Buffer) ->
    PrefacePrefix = binary:part(?H2_PREFACE, 0, byte_size(Buffer)),
    Buffer =:= PrefacePrefix.

handle_data(Data, #state{protocol = h1, protocol_state = ProtocolState,
                          socket = Socket, transport = Transport} = State) ->
    %% Cancel old timer, start new one
    cancel_timer(State#state.timer_ref),

    case livery_h1:handle_data(Data, ProtocolState) of
        {ok, NewProtocolState} ->
            %% Need more data
            ok = set_active(Socket, Transport),
            TimerRef = erlang:start_timer(State#state.request_timeout, self(), request_timeout),
            {next_state, active, State#state{protocol_state = NewProtocolState, timer_ref = TimerRef}};

        {continue, NewProtocolState} ->
            %% Send 100 Continue response
            ContinueResponse = <<"HTTP/1.1 100 Continue\r\n\r\n">>,
            case send_data(Socket, Transport, ContinueResponse) of
                ok ->
                    %% Mark continue as sent and continue reading body
                    NextProtocolState = livery_h1:continue_sent(NewProtocolState),
                    ok = set_active(Socket, Transport),
                    TimerRef = erlang:start_timer(State#state.request_timeout, self(), request_timeout),
                    {next_state, active, State#state{protocol_state = NextProtocolState, timer_ref = TimerRef}};
                {error, _Reason} ->
                    {stop, normal, State#state{protocol_state = NewProtocolState}}
            end;

        {response, Status, Headers, Body, NewProtocolState} ->
            %% Send response
            case livery_h1:send_response(Socket, Status, Headers, Body, NewProtocolState) of
                {ok, NextProtocolState} ->
                    %% Ready for next request (keep-alive)
                    ok = set_active(Socket, Transport),
                    TimerRef = erlang:start_timer(State#state.idle_timeout, self(), idle_timeout),
                    {next_state, waiting, State#state{
                        protocol_state = NextProtocolState,
                        timer_ref = TimerRef
                    }};
                {close, _} ->
                    {stop, normal, State#state{protocol_state = NewProtocolState}}
            end;

        {stream, Status, Headers, StreamFun, NewProtocolState} ->
            %% Send streaming response
            case livery_h1:send_stream(Socket, Status, Headers, StreamFun, NewProtocolState) of
                {ok, NextProtocolState} ->
                    %% Ready for next request (keep-alive)
                    ok = set_active(Socket, Transport),
                    TimerRef = erlang:start_timer(State#state.idle_timeout, self(), idle_timeout),
                    {next_state, waiting, State#state{
                        protocol_state = NextProtocolState,
                        timer_ref = TimerRef
                    }};
                {close, _} ->
                    {stop, normal, State#state{protocol_state = NewProtocolState}}
            end;

        {close, NewProtocolState} ->
            {stop, normal, State#state{protocol_state = NewProtocolState}};

        {error, Reason, NewProtocolState} ->
            send_error_response(error_to_status(Reason), State),
            {stop, {shutdown, Reason}, State#state{protocol_state = NewProtocolState}}
    end;

handle_data(Data, #state{protocol = h2, protocol_state = ProtocolState,
                          socket = Socket, transport = Transport,
                          handler = Handler, handler_opts = HandlerOpts,
                          peer = Peer, idle_timeout = IdleTimeout} = State) ->
    %% Cancel old timer
    cancel_timer(State#state.timer_ref),

    case livery_h2:handle_data(Data, ProtocolState) of
        {ok, Responses, NewProtocolState} ->
            %% Check if settings were acked - cancel settings timer
            NewSettingsTimer = case lists:member(settings_acked, Responses) of
                true ->
                    cancel_timer(State#state.settings_timer_ref),
                    undefined;
                false ->
                    State#state.settings_timer_ref
            end,
            %% Filter out settings_acked before processing
            FilteredResponses = [R || R <- Responses, R =/= settings_acked],
            %% Process all responses and requests
            case process_h2_responses(FilteredResponses, Socket, Transport, Handler,
                                       HandlerOpts, Peer, NewProtocolState) of
                {ok, FinalProtocolState} ->
                    ok = set_active(Socket, Transport),
                    TimerRef = erlang:start_timer(IdleTimeout, self(), idle_timeout),
                    {next_state, waiting, State#state{
                        protocol_state = FinalProtocolState,
                        timer_ref = TimerRef,
                        settings_timer_ref = NewSettingsTimer
                    }};
                {error, Reason, FinalProtocolState} ->
                    %% Send GOAWAY and close
                    GoawayFrame = livery_h2:close(h2_error_code(Reason), FinalProtocolState),
                    send_data(Socket, Transport, GoawayFrame),
                    {stop, {shutdown, Reason}, State#state{protocol_state = FinalProtocolState}}
            end;

        {error, Reason, NewProtocolState} ->
            %% Protocol error - send GOAWAY and close
            GoawayFrame = livery_h2:close(h2_error_code(Reason), NewProtocolState),
            send_data(Socket, Transport, GoawayFrame),
            {stop, {shutdown, Reason}, State#state{protocol_state = NewProtocolState}}
    end;

handle_data(_Data, State) ->
    %% Unknown protocol
    {keep_state, State}.

get_peername(Socket, gen_tcp) ->
    inet:peername(Socket);
get_peername(Socket, ssl) ->
    ssl:peername(Socket).

set_active(Socket, gen_tcp) ->
    inet:setopts(Socket, [{active, once}]);
set_active(Socket, ssl) ->
    ssl:setopts(Socket, [{active, once}]).

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    erlang:cancel_timer(Ref),
    ok.

send_error_response(Status, #state{socket = Socket, transport = Transport}) ->
    Body = livery_resp:status_text(Status),
    Response = livery_resp:build(Status, [{<<"content-type">>, <<"text/plain">>}], Body, {1, 1}),
    case Transport of
        gen_tcp -> gen_tcp:send(Socket, Response);
        ssl -> ssl:send(Socket, Response)
    end.

error_to_status(invalid_method) -> 400;
error_to_status(method_too_long) -> 400;
error_to_status(uri_too_long) -> 414;
error_to_status(invalid_uri) -> 400;
error_to_status(invalid_version) -> 400;
error_to_status(header_name_too_long) -> 400;
error_to_status(header_value_too_long) -> 400;
error_to_status(invalid_header_name) -> 400;
error_to_status(invalid_header_value) -> 400;
error_to_status(too_many_headers) -> 400;
error_to_status(missing_host_header) -> 400;
error_to_status(invalid_chunk_size) -> 400;
error_to_status(chunk_size_too_long) -> 400;
error_to_status(chunk_too_large) -> 413;
error_to_status(invalid_chunk_terminator) -> 400;
error_to_status(body_too_large) -> 413;
error_to_status(_) -> 500.

%% Send data to socket
send_data(Socket, gen_tcp, Data) ->
    gen_tcp:send(Socket, Data);
send_data(Socket, ssl, Data) ->
    ssl:send(Socket, Data).

%% Process HTTP/2 responses and requests
process_h2_responses([], _Socket, _Transport, _Handler, _HandlerOpts, _Peer, State) ->
    {ok, State};
process_h2_responses([{send, IoData} | Rest], Socket, Transport, Handler,
                      HandlerOpts, Peer, State) ->
    case send_data(Socket, Transport, IoData) of
        ok ->
            process_h2_responses(Rest, Socket, Transport, Handler, HandlerOpts, Peer, State);
        {error, Reason} ->
            {error, Reason, State}
    end;
process_h2_responses([{request, StreamId, H2Request} | Rest], Socket, Transport,
                      Handler, HandlerOpts, Peer, State) ->
    case handle_h2_request(StreamId, H2Request, Socket, Transport, Handler,
                            HandlerOpts, Peer, State) of
        {ok, NewState} ->
            process_h2_responses(Rest, Socket, Transport, Handler, HandlerOpts, Peer, NewState);
        {error, Reason, NewState} ->
            {error, Reason, NewState}
    end;
process_h2_responses([{http_error, StreamId, Status} | Rest], Socket, Transport,
                      Handler, HandlerOpts, Peer, State) ->
    %% HTTP-level error (e.g., 431 Request Header Fields Too Large)
    case send_h2_error_response(StreamId, Status, Socket, Transport, State) of
        {ok, NewState} ->
            process_h2_responses(Rest, Socket, Transport, Handler, HandlerOpts, Peer, NewState);
        {error, Reason, NewState} ->
            {error, Reason, NewState}
    end;
process_h2_responses([{tunnel_data, StreamId, Data} | Rest], Socket, Transport,
                      Handler, HandlerOpts, Peer, State) ->
    %% CONNECT tunnel data - deliver to handler if it implements handle_tunnel_data/4
    case erlang:function_exported(Handler, handle_tunnel_data, 4) of
        true ->
            %% Handler supports tunnel mode
            case Handler:handle_tunnel_data(StreamId, Data, Socket, State) of
                {ok, NewState} ->
                    process_h2_responses(Rest, Socket, Transport, Handler, HandlerOpts, Peer, NewState);
                {send, IoData, NewState} ->
                    case send_data(Socket, Transport, IoData) of
                        ok ->
                            process_h2_responses(Rest, Socket, Transport, Handler, HandlerOpts, Peer, NewState);
                        {error, Reason} ->
                            {error, Reason, NewState}
                    end;
                {error, Reason, NewState} ->
                    {error, Reason, NewState}
            end;
        false ->
            %% Handler doesn't support tunnels - log and ignore
            error_logger:warning_msg("CONNECT tunnel data on stream ~p ignored (handler ~p doesn't support tunnels)~n",
                                     [StreamId, Handler]),
            process_h2_responses(Rest, Socket, Transport, Handler, HandlerOpts, Peer, State)
    end;
process_h2_responses([{tunnel_closed, StreamId} | Rest], Socket, Transport,
                      Handler, HandlerOpts, Peer, State) ->
    %% CONNECT tunnel closed by peer
    case erlang:function_exported(Handler, handle_tunnel_closed, 3) of
        true ->
            case Handler:handle_tunnel_closed(StreamId, Socket, State) of
                {ok, NewState} ->
                    process_h2_responses(Rest, Socket, Transport, Handler, HandlerOpts, Peer, NewState);
                {error, Reason, NewState} ->
                    {error, Reason, NewState}
            end;
        false ->
            process_h2_responses(Rest, Socket, Transport, Handler, HandlerOpts, Peer, State)
    end.

%% Handle an HTTP/2 request
handle_h2_request(StreamId, H2Request, Socket, Transport, Handler, HandlerOpts, Peer, State) ->
    %% Convert H2 request to livery_req
    Req = livery_h2:request_to_livery_req(H2Request, Handler, HandlerOpts, Peer),

    %% Call handler
    try
        case Handler:init(Req, HandlerOpts) of
            {ok, Req1, HandlerState} ->
                case Handler:handle(Req1, HandlerState) of
                    {reply, Status, Headers, Body, _NewHandlerState} ->
                        %% Send response
                        {ok, ResponseFrames, NewState} =
                            livery_h2:send_response(StreamId, Status, Headers, Body, State),
                        case send_data(Socket, Transport, ResponseFrames) of
                            ok -> {ok, NewState};
                            {error, Reason} -> {error, Reason, NewState}
                        end;
                    {stream, Status, Headers, StreamFun, _NewHandlerState} ->
                        %% Send streaming response
                        handle_h2_stream_response(StreamId, Status, Headers, StreamFun,
                                                   Socket, Transport, State);
                    Other ->
                        %% Unexpected handler response
                        error_logger:warning_msg("Unexpected handler response: ~p~n", [Other]),
                        send_h2_error_response(StreamId, 500, Socket, Transport, State)
                end;
            {error, _Reason} ->
                send_h2_error_response(StreamId, 500, Socket, Transport, State)
        end
    catch
        Class:Error:Stacktrace ->
            error_logger:error_msg("Handler error: ~p:~p~n~p~n",
                                   [Class, Error, Stacktrace]),
            send_h2_error_response(StreamId, 500, Socket, Transport, State)
    end.

%% Handle H2 streaming response
handle_h2_stream_response(StreamId, Status, Headers, StreamFun, Socket, Transport, State) ->
    %% Send initial headers (no END_STREAM)
    {ok, HeaderFrames, State1} = livery_h2:send_response(StreamId, Status, Headers, <<>>, State),
    case send_data(Socket, Transport, HeaderFrames) of
        ok ->
            stream_h2_with_callback(StreamId, StreamFun, Socket, Transport, State1);
        {error, Reason} ->
            {error, Reason, State1}
    end.

%% Stream chunks for H2 using callback-based StreamFun
%% StreamFun takes a SendFun callback and calls it for each chunk
stream_h2_with_callback(StreamId, StreamFun, Socket, Transport, State) ->
    %% Use process dictionary to track state across callback invocations
    %% since the callback is synchronous
    StateRef = make_ref(),
    put(StateRef, {State, ok}),

    SendFun = fun
        (done) ->
            {CurrentState, _Status} = get(StateRef),
            case livery_h2:send_stream_end(StreamId, CurrentState) of
                {ok, DataFrame, NewState} ->
                    case send_data(Socket, Transport, DataFrame) of
                        ok ->
                            put(StateRef, {NewState, ok}),
                            ok;
                        {error, Reason} ->
                            put(StateRef, {NewState, {error, Reason}}),
                            ok
                    end
            end;
        ({done, Trailers}) ->
            %% Send trailers (HEADERS frame with END_STREAM)
            {CurrentState, _Status} = get(StateRef),
            {ok, TrailerFrames, NewState} = livery_h2:send_trailers(StreamId, Trailers, CurrentState),
            case send_data(Socket, Transport, TrailerFrames) of
                ok ->
                    put(StateRef, {NewState, ok}),
                    ok;
                {error, Reason} ->
                    put(StateRef, {NewState, {error, Reason}}),
                    ok
            end;
        (Chunk) ->
            {CurrentState, _Status} = get(StateRef),
            case livery_h2:send_stream_data(StreamId, Chunk, false, CurrentState) of
                {ok, DataFrame, NewState} ->
                    case send_data(Socket, Transport, DataFrame) of
                        ok ->
                            put(StateRef, {NewState, ok}),
                            ok;
                        {error, Reason} ->
                            put(StateRef, {NewState, {error, Reason}}),
                            ok
                    end;
                {buffered, _BytesPending, NewState} ->
                    %% Data buffered due to flow control
                    put(StateRef, {NewState, ok}),
                    ok
            end
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

%% Send an error response for H2
send_h2_error_response(StreamId, Status, Socket, Transport, State) ->
    Body = livery_resp:status_text(Status),
    Headers = [{<<"content-type">>, <<"text/plain">>}],
    {ok, ResponseFrames, NewState} = livery_h2:send_response(StreamId, Status, Headers, Body, State),
    case send_data(Socket, Transport, ResponseFrames) of
        ok -> {ok, NewState};
        {error, Reason} -> {error, Reason, NewState}
    end.

%% Map error reasons to HTTP/2 error codes
h2_error_code({protocol_error, _}) -> 1;  %% PROTOCOL_ERROR
h2_error_code(protocol_error) -> 1;
h2_error_code({compression_error, _}) -> 9;  %% COMPRESSION_ERROR
h2_error_code(flow_control_error) -> 3;  %% FLOW_CONTROL_ERROR
h2_error_code({goaway, _, ErrorCode}) -> ErrorCode;
h2_error_code(_) -> 0.  %% NO_ERROR
