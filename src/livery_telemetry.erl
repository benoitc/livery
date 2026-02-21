%% @doc Telemetry events for Livery HTTP server.
%%
%% Livery emits telemetry events for monitoring and observability.
%% Events follow the telemetry naming convention: [livery, component, action].
%%
%% == Events ==
%%
%% === Connection Events ===
%% - `[livery, connection, start]' - Connection accepted
%%   Measurements: `#{system_time => integer()}'
%%   Metadata: `#{listener => atom(), peer => {ip(), port()}, transport => tcp | ssl}'
%%
%% - `[livery, connection, stop]' - Connection closed
%%   Measurements: `#{duration => integer()}' (native time units)
%%   Metadata: `#{listener => atom(), peer => {ip(), port()}, reason => term()}'
%%
%% === Request Events ===
%% - `[livery, request, start]' - Request received
%%   Measurements: `#{system_time => integer()}'
%%   Metadata: `#{method => binary(), path => binary(), protocol => h1 | h2 | h3}'
%%
%% - `[livery, request, stop]' - Request completed
%%   Measurements: `#{duration => integer(), resp_body_size => integer()}'
%%   Metadata: `#{method => binary(), path => binary(), status => integer()}'
%%
%% - `[livery, request, exception]' - Request failed with exception
%%   Measurements: `#{duration => integer()}'
%%   Metadata: `#{method => binary(), path => binary(), kind => error | exit | throw,
%%                reason => term(), stacktrace => list()}'
%%
%% === WebSocket Events ===
%% - `[livery, websocket, upgrade]' - WebSocket upgrade
%%   Measurements: `#{system_time => integer()}'
%%   Metadata: `#{path => binary()}'
%%
%% - `[livery, websocket, frame]' - WebSocket frame sent/received
%%   Measurements: `#{size => integer()}'
%%   Metadata: `#{direction => in | out, opcode => atom()}'
%%
%% == Usage ==
%%
%% Attach handlers using telemetry:attach/4:
%% ```
%% telemetry:attach(
%%     <<"my-handler">>,
%%     [livery, request, stop],
%%     fun handle_event/4,
%%     #{}
%% ).
%% '''
-module(livery_telemetry).

-export([
    %% Connection events
    connection_start/2,
    connection_stop/3,
    %% Request events
    request_start/2,
    request_stop/3,
    request_exception/4,
    %% WebSocket events
    websocket_upgrade/1,
    websocket_frame/3,
    %% Span helpers
    span/3
]).

-define(APP, livery).

%%====================================================================
%% Connection Events
%%====================================================================

%% @doc Emit connection start event.
-spec connection_start(atom(), map()) -> integer().
connection_start(Listener, Metadata) ->
    StartTime = erlang:monotonic_time(),
    emit([?APP, connection, start],
         #{system_time => erlang:system_time()},
         Metadata#{listener => Listener}),
    StartTime.

%% @doc Emit connection stop event.
-spec connection_stop(integer(), atom(), map()) -> ok.
connection_stop(StartTime, Reason, Metadata) ->
    Duration = erlang:monotonic_time() - StartTime,
    emit([?APP, connection, stop],
         #{duration => Duration},
         Metadata#{reason => Reason}).

%%====================================================================
%% Request Events
%%====================================================================

%% @doc Emit request start event. Returns start time for duration calculation.
-spec request_start(binary(), map()) -> integer().
request_start(Method, Metadata) ->
    StartTime = erlang:monotonic_time(),
    emit([?APP, request, start],
         #{system_time => erlang:system_time()},
         Metadata#{method => Method}),
    StartTime.

%% @doc Emit request stop event.
-spec request_stop(integer(), integer(), map()) -> ok.
request_stop(StartTime, Status, Metadata) ->
    Duration = erlang:monotonic_time() - StartTime,
    RespBodySize = maps:get(resp_body_size, Metadata, 0),
    emit([?APP, request, stop],
         #{duration => Duration, resp_body_size => RespBodySize},
         Metadata#{status => Status}).

%% @doc Emit request exception event.
%% Stacktrace should be captured using try/catch with :Stacktrace syntax.
-spec request_exception(integer(), error | exit | throw, term(), map()) -> ok.
request_exception(StartTime, Kind, Reason, Metadata) ->
    Duration = erlang:monotonic_time() - StartTime,
    emit([?APP, request, exception],
         #{duration => Duration},
         Metadata#{kind => Kind, reason => Reason}).

%%====================================================================
%% WebSocket Events
%%====================================================================

%% @doc Emit WebSocket upgrade event.
-spec websocket_upgrade(map()) -> ok.
websocket_upgrade(Metadata) ->
    emit([?APP, websocket, upgrade],
         #{system_time => erlang:system_time()},
         Metadata).

%% @doc Emit WebSocket frame event.
-spec websocket_frame(in | out, atom(), non_neg_integer()) -> ok.
websocket_frame(Direction, Opcode, Size) ->
    emit([?APP, websocket, frame],
         #{size => Size},
         #{direction => Direction, opcode => Opcode}).

%%====================================================================
%% Span Helper
%%====================================================================

%% @doc Execute a function and emit start/stop events.
%% Useful for wrapping operations with automatic telemetry.
-spec span([atom()], map(), fun(() -> Result)) -> Result when Result :: term().
span(EventPrefix, Metadata, Fun) ->
    StartTime = erlang:monotonic_time(),
    emit(EventPrefix ++ [start],
         #{system_time => erlang:system_time()},
         Metadata),
    try Fun() of
        Result ->
            Duration = erlang:monotonic_time() - StartTime,
            emit(EventPrefix ++ [stop],
                 #{duration => Duration},
                 Metadata),
            Result
    catch
        Kind:Reason:Stacktrace ->
            EndTime = erlang:monotonic_time(),
            emit(EventPrefix ++ [exception],
                 #{duration => EndTime - StartTime},
                 Metadata#{kind => Kind, reason => Reason, stacktrace => Stacktrace}),
            erlang:raise(Kind, Reason, Stacktrace)
    end.

%%====================================================================
%% Internal
%%====================================================================

%% @private Emit telemetry event if telemetry is available.
emit(Event, Measurements, Metadata) ->
    %% Check if telemetry is available at runtime
    case code:is_loaded(telemetry) of
        {file, _} ->
            telemetry:execute(Event, Measurements, Metadata);
        false ->
            %% Telemetry not available, silently ignore
            ok
    end.
