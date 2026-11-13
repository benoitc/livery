-module(livery_engine_bridge).
-moduledoc """
Shared bridge to the transport-neutral protocol engines.

`livery_mcp` and `livery_a2a` hand a request to an engine
(`barrel_mcp_http_engine`, `barrel_a2a_http_engine`) that owns its
protocol and answers through a responder: a map of callbacks that
write to the stream. This module is the Livery side of that hand-off,
so every engine reads the body under the same limits, answers the same
way when a body is too large, too slow or cut off, and writes through
the adapter the same way.

You do not call it directly; mount `livery_mcp` or `livery_a2a`.
""".

-include("livery.hrl").

-export([limits/1, serve/4]).

-export_type([limits/0]).

-type limits() :: {MaxBytes :: pos_integer(), TimeoutMs :: pos_integer()}.

-define(DEFAULT_MAX_BODY_BYTES, 16 * 1024 * 1024).
-define(DEFAULT_BODY_TIMEOUT, 60000).

-doc """
Body limits from the `max_body_bytes` (default 16 MiB) and
`body_timeout_ms` (default 60000, the longest wait for one chunk)
options.
""".
-spec limits(map()) -> limits().
limits(Opts) ->
    {
        maps:get(max_body_bytes, Opts, ?DEFAULT_MAX_BODY_BYTES),
        maps:get(body_timeout_ms, Opts, ?DEFAULT_BODY_TIMEOUT)
    }.

-doc """
Read the body under `Limits`, then call `Handle(Body, Responder)`.

`Responder` holds the `reply`, `stream_start`, `stream_chunk` and
`stream_end` callbacks, plus whatever `Extra` adds. `Handle` writes the
whole response through it, so the result is the `taken_over` sentinel.
A body over the limit, or the listener's `max_body`, is answered `413`;
a body that stalls past the timeout `408`; one that ends any other way
`400`. The engine never sees those requests.
""".
-spec serve(livery_req:req(), limits(), map(), fun((binary(), map()) -> ok)) ->
    livery_resp:resp().
serve(Req, Limits, Extra, Handle) ->
    case read_body(Req, Limits) of
        {ok, Body} ->
            Responder = maps:merge(
                responder(livery_req:adapter(Req), livery_req:stream(Req)), Extra
            ),
            ok = Handle(Body, Responder),
            #livery_resp{status = 200, body = taken_over};
        {error, too_large} ->
            livery_resp:text(413, <<"Request body too large">>);
        {error, timeout} ->
            livery_resp:text(408, <<"Request body timeout">>);
        {error, _} ->
            livery_resp:text(400, <<"Request body incomplete">>)
    end.

%%====================================================================
%% Internals
%%====================================================================

-spec read_body(livery_req:req(), limits()) ->
    {ok, binary()} | {error, too_large | timeout | term()}.
read_body(Req, {Max, Timeout}) ->
    case livery_req:body(Req) of
        empty ->
            {ok, <<>>};
        {buffered, IoData} ->
            case iolist_size(IoData) > Max of
                true -> {error, too_large};
                false -> {ok, iolist_to_binary(IoData)}
            end;
        {stream, Reader} ->
            case livery_body:read_all(Reader, Timeout, Max) of
                {ok, Bytes, _} -> {ok, Bytes};
                {error, {limit, max_size}, _} -> {error, too_large};
                {error, body_too_large, _} -> {error, too_large};
                {error, Reason, _} -> {error, Reason}
            end
    end.

-spec responder(module(), term()) -> map().
responder(Adapter, Stream) ->
    #{
        reply => fun(Status, Headers, Body) ->
            Bin = iolist_to_binary(Body),
            Hdrs = ensure_content_length(Headers, byte_size(Bin)),
            case Adapter:send_headers(Stream, Status, Hdrs, #{end_stream => false}) of
                {error, closed} ->
                    %% Peer gone: drop the body, the stream is already over.
                    ok;
                _ ->
                    _ = Adapter:send_data(Stream, Bin, #{end_stream => true}),
                    ok
            end
        end,
        stream_start => fun(Status, Headers) ->
            _ = Adapter:send_headers(Stream, Status, Headers, #{end_stream => false}),
            ok
        end,
        stream_chunk => fun(Data) ->
            Adapter:send_data(Stream, iolist_to_binary(Data), #{end_stream => false})
        end,
        stream_end => fun() ->
            _ = Adapter:send_data(Stream, <<>>, #{end_stream => true}),
            ok
        end
    }.

-spec ensure_content_length([{binary(), binary()}], non_neg_integer()) ->
    [{binary(), binary()}].
ensure_content_length(Headers, Len) ->
    HasFraming = lists:any(
        fun({K, _}) ->
            L = string:lowercase(K),
            L =:= <<"content-length">> orelse L =:= <<"transfer-encoding">>
        end,
        Headers
    ),
    case HasFraming of
        true -> Headers;
        false -> [{<<"content-length">>, integer_to_binary(Len)} | Headers]
    end.
