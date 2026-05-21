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
Instruments are created lazily on first request and cached in
`persistent_term/1` keyed by meter name.
""".
-behaviour(livery_middleware).

-export([call/3]).

-spec call(livery_req:req(), livery_middleware:next(), map()) ->
    livery_resp:resp().
call(Req, Next, State) ->
    Meter = maps:get(meter, State, <<"livery">>),
    {Active, Duration} = get_instruments(Meter),
    StartAttrs = active_attrs(Req),
    _ = instrument_meter:add(Active, 1, StartAttrs),
    Start = erlang:monotonic_time(),
    try
        Resp = Next(Req),
        Elapsed = erlang:monotonic_time() - Start,
        Secs = erlang:convert_time_unit(Elapsed, native, microsecond) / 1.0e6,
        _ = instrument_meter:record(Duration, Secs, dur_attrs(Req, Resp)),
        Resp
    after
        _ = instrument_meter:add(Active, -1, StartAttrs)
    end.

-spec get_instruments(binary() | atom()) ->
    {instrument_meter:instrument(), instrument_meter:instrument()}.
get_instruments(Meter) ->
    Key = {?MODULE, Meter},
    case persistent_term:get(Key, undefined) of
        undefined ->
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
            Pair = {Active, Duration},
            ok = persistent_term:put(Key, Pair),
            Pair;
        Pair ->
            Pair
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
