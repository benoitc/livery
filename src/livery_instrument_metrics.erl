-module(livery_instrument_metrics).
-moduledoc """
HTTP server metrics middleware powered by the `instrument`
library.

Records the OpenTelemetry HTTP server semantic-convention metrics
on every request:

- `http.server.active_requests` (up_down_counter): incremented on
  request entry, decremented on exit.
- `http.server.request.duration` (histogram, seconds): wall-clock
  time from middleware entry to response return.

Attributes follow the conventions:

- `http.request.method`
- `http.response.status_code`
- `network.protocol.name`
- `url.scheme`

State: `#{meter => binary() | atom()}` (defaults to `<<"livery">>`).
Instruments are resolved from the `instrument` registry on each request
(`create_*` is idempotent and returns the existing handle by name), so
the registry is the single source of truth and a registry restart
self-heals. If the registry is unavailable, the request is served
without metrics rather than failing.
""".
-behaviour(livery_middleware).

-export([call/3]).

-spec call(livery_req:req(), livery_middleware:next(), map()) ->
    livery_resp:resp().
call(Req, Next, State) ->
    Meter = maps:get(meter, State, <<"livery">>),
    case instruments(Meter) of
        {Active, Duration} ->
            measure(Req, Next, Active, Duration);
        skip ->
            %% Instrument registry unavailable (e.g. restarting): serve
            %% the request without metrics rather than failing it.
            Next(Req)
    end.

%% Resolve the instrument pair from instrument's own registry. create_*
%% is idempotent (persistent_term-backed by name), so this is a couple of
%% registry reads on the hot path and the registry stays the single source
%% of truth (a registry restart self-heals). Creation goes through
%% instrument_registry (a gen_server:call), which exits `noproc' if the
%% registry is down/restarting; catch that (and anything else) so an
%% instrument outage never fails the request.
-spec instruments(binary() | atom()) ->
    {instrument_meter:instrument(), instrument_meter:instrument()} | skip.
instruments(Meter) ->
    try
        M = instrument_meter:get_meter(Meter),
        Active = instrument_meter:create_up_down_counter(
            M,
            <<"http.server.active_requests">>,
            #{
                description => <<"Number of active HTTP server requests">>,
                unit => <<"{request}">>
            }
        ),
        Duration = instrument_meter:create_histogram(
            M,
            <<"http.server.request.duration">>,
            #{
                description => <<"Duration of HTTP server requests">>,
                unit => <<"s">>
            }
        ),
        {Active, Duration}
    catch
        _Class:_Reason -> skip
    end.

-spec measure(
    livery_req:req(),
    livery_middleware:next(),
    instrument_meter:instrument(),
    instrument_meter:instrument()
) -> livery_resp:resp().
measure(Req, Next, Active, Duration) ->
    StartAttrs = active_attrs(Req),
    track(fun() -> instrument_meter:add(Active, 1, StartAttrs) end),
    Start = erlang:monotonic_time(),
    try
        Resp = Next(Req),
        Elapsed = erlang:monotonic_time() - Start,
        Secs = erlang:convert_time_unit(Elapsed, native, microsecond) / 1.0e6,
        track(fun() -> instrument_meter:record(Duration, Secs, dur_attrs(Req, Resp)) end),
        Resp
    after
        track(fun() -> instrument_meter:add(Active, -1, StartAttrs) end)
    end.

%% Metrics are best-effort: never let a metric op fail the request.
-spec track(fun(() -> term())) -> ok.
track(Fun) ->
    try
        _ = Fun(),
        ok
    catch
        _Class:_Reason -> ok
    end.

-spec active_attrs(livery_req:req()) -> map().
active_attrs(Req) ->
    #{
        <<"http.request.method">> => livery_req:method(Req),
        <<"url.scheme">> => livery_req:scheme(Req),
        <<"network.protocol.name">> => livery_instrument_trace_protocol(livery_req:protocol(Req))
    }.

-spec dur_attrs(livery_req:req(), livery_resp:resp()) -> map().
dur_attrs(Req, Resp) ->
    M = active_attrs(Req),
    M#{<<"http.response.status_code">> => livery_resp:status(Resp)}.

%% Reuse the same protocol-name mapping as the tracer middleware to
%% keep label sets in sync without coupling the modules.
-spec livery_instrument_trace_protocol(h1 | h2 | h3) -> binary().
livery_instrument_trace_protocol(h1) -> <<"http/1.1">>;
livery_instrument_trace_protocol(h2) -> <<"http/2">>;
livery_instrument_trace_protocol(h3) -> <<"http/3">>.
