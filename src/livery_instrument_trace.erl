-module(livery_instrument_trace).
-moduledoc """
Tracing middleware powered by the `instrument` library.

Opens one server span per request, attaches OpenTelemetry HTTP
server semantic attributes (method, status, route, scheme,
protocol, peer), and propagates W3C `traceparent`/`tracestate`
context extracted from the inbound headers.

State: `#{tracer => binary() | atom()}` (defaults to
`<<"livery">>`).

The span is `kind => server` and gets these attributes:

- `http.request.method`
- `url.path`
- `url.scheme`
- `network.protocol.name` (`http/1.1` / `http/2` / `http/3`)
- `server.address`
- `client.address`
- `user_agent.original`
- `http.response.status_code` (set after the handler returns)

Errors from the handler are recorded on the span via
`instrument_tracer:record_exception/2` and re-raised so the
request process's own crash handling still runs.
""".
-behaviour(livery_middleware).

-export([call/3]).

-spec call(livery_req:req(), livery_middleware:next(),
           map()) -> livery_resp:resp().
call(Req, Next, State) ->
    Parent = extract_parent(Req),
    Opts = #{
        kind       => server,
        parent     => Parent,
        attributes => request_attrs(Req)
    },
    Name = maps:get(tracer, State, <<"livery">>),
    instrument_tracer:with_span(Name, Opts, fun() ->
        Resp = Next(Req),
        _ = instrument_tracer:set_attributes(response_attrs(Resp)),
        Resp
    end).

extract_parent(Req) ->
    case livery_req:headers(Req) of
        [] ->
            undefined;
        Hs ->
            Ctx = instrument_propagation:extract_headers(Hs),
            %% start_span expects a #span_ctx{} record (or `undefined`),
            %% not the surrounding context map.
            instrument_context:get_value(Ctx, span_ctx)
    end.

-spec request_attrs(livery_req:req()) -> map().
request_attrs(Req) ->
    Base = #{
        <<"http.request.method">>    => livery_req:method(Req),
        <<"url.path">>               => livery_req:path(Req),
        <<"url.scheme">>             => livery_req:scheme(Req),
        <<"network.protocol.name">>  => network_protocol(livery_req:protocol(Req))
    },
    Base1 = put_if_set(<<"server.address">>, livery_req:authority(Req), Base),
    Base2 = put_if_set(<<"user_agent.original">>,
                       livery_req:header(<<"user-agent">>, Req), Base1),
    put_peer(livery_req:peer(Req), Base2).

-spec response_attrs(livery_resp:resp()) -> map().
response_attrs(Resp) ->
    #{<<"http.response.status_code">> => livery_resp:status(Resp)}.

-spec network_protocol(h1 | h2 | h3) -> binary().
network_protocol(h1) -> <<"http/1.1">>;
network_protocol(h2) -> <<"http/2">>;
network_protocol(h3) -> <<"http/3">>.

-spec put_peer({inet:ip_address(), inet:port_number()} | undefined, map()) -> map().
put_peer(undefined, M) -> M;
put_peer({IP, _Port}, M) ->
    M#{<<"client.address">> => iolist_to_binary(inet:ntoa(IP))}.

-spec put_if_set(binary(), term() | undefined, map()) -> map().
put_if_set(_K, undefined, M) -> M;
put_if_set(_K, <<>>, M)      -> M;
put_if_set(K, V, M)          -> M#{K => V}.
