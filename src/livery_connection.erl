%% @doc Connection handler process.
%%
%% One process per connection, manages the lifecycle of a connection
%% and delegates to the appropriate protocol handler.
-module(livery_connection).

-behaviour(gen_statem).

-include("livery.hrl").

%% API
-export([start_link/4]).

%% gen_statem callbacks
-export([
    callback_mode/0,
    init/1,
    activating/3,
    waiting/3,
    active/3,
    terminate/3
]).

-record(state, {
    socket :: gen_tcp:socket() | ssl:sslsocket(),
    transport :: gen_tcp | ssl,
    handler :: module(),
    handler_opts :: term(),
    protocol :: h1 | h2 | h3,
    protocol_state :: livery_h1:state() | term(),
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    request_timeout :: timeout(),
    idle_timeout :: timeout(),
    timer_ref :: reference() | undefined
}).

%% API

-spec start_link(gen_tcp:socket() | ssl:sslsocket(), gen_tcp | ssl, module(), term()) ->
    {ok, pid()} | {error, term()}.
start_link(Socket, Transport, Handler, HandlerOpts) ->
    gen_statem:start_link(?MODULE, {Socket, Transport, Handler, HandlerOpts}, []).

%% gen_statem callbacks

-spec callback_mode() -> state_functions.
callback_mode() ->
    state_functions.

-spec init({gen_tcp:socket() | ssl:sslsocket(), gen_tcp | ssl, module(), term()}) ->
    gen_statem:init_result(activating).
init({Socket, Transport, Handler, HandlerOpts}) ->
    %% Get timeouts from application config
    RequestTimeout = application:get_env(livery, request_timeout, 60000),
    IdleTimeout = application:get_env(livery, idle_timeout, 300000),

    %% Initialize protocol state (H1 for now)
    ProtocolState = livery_h1:init(Handler, HandlerOpts),

    State = #state{
        socket = Socket,
        transport = Transport,
        handler = Handler,
        handler_opts = HandlerOpts,
        protocol = h1,
        protocol_state = ProtocolState,
        peer = undefined,
        request_timeout = RequestTimeout,
        idle_timeout = IdleTimeout
    },

    %% Acceptor will send activate_socket message after transferring ownership
    %% Set a timeout in case activate message never arrives
    {ok, activating, State, [{state_timeout, 5000, activate_timeout}]}.

%% Activating - waiting for socket ownership before activating
-spec activating(gen_statem:event_type(), term(), #state{}) ->
    gen_statem:event_handler_result(atom()).
activating(info, activate_socket, #state{socket = Socket, transport = Transport,
                                          idle_timeout = IdleTimeout} = State) ->
    %% Now we have ownership - get peer info and activate socket
    Peer = case get_peername(Socket, Transport) of
        {ok, P} -> P;
        _ -> undefined
    end,
    case set_active(Socket, Transport) of
        ok ->
            TimerRef = erlang:start_timer(IdleTimeout, self(), idle_timeout),
            {next_state, waiting, State#state{peer = Peer, timer_ref = TimerRef}};
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
terminate(_Reason, _StateName, #state{socket = Socket, transport = Transport}) ->
    Transport:close(Socket),
    ok.

%% Internal functions

handle_common(_EventType, _Event, State) ->
    {keep_state, State}.

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
handle_data(_Data, State) ->
    %% Non-H1 protocols not implemented in Phase 1
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
error_to_status(invalid_chunk_size) -> 400;
error_to_status(chunk_size_too_long) -> 400;
error_to_status(chunk_too_large) -> 413;
error_to_status(invalid_chunk_terminator) -> 400;
error_to_status(body_too_large) -> 413;
error_to_status(_) -> 500.
