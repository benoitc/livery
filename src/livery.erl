-module(livery).
-moduledoc """
Public Livery facade.

Holds the user-visible API for service lifecycle plus the shared
response-emission walker that every adapter calls back into.
""".

-include("livery.hrl").

-export([
    start_listener/2,
    stop_listener/1,
    start_service/1,
    stop_service/1,
    drain/1,
    drain/2,
    which_listeners/1,
    router_handler/1,
    router_handler/2,
    dispatch/3,
    emit/3
]).

%%====================================================================
%% Service lifecycle
%%====================================================================

-doc """
Start a single-protocol listener. Useful for serving over just
one wire; for multi-protocol services with Alt-Svc, use
`start_service/1`.

`Name` selects the adapter (`livery_h1`, `livery_h2`, or
`livery_h3`). `Opts` is the adapter's `listen_opts()` map.
""".
-spec start_listener(atom(), map()) -> {ok, term()} | {error, term()}.
start_listener(livery_h1, Opts) -> livery_h1:start(Opts);
start_listener(livery_h2, Opts) -> livery_h2:start(Opts);
start_listener(livery_h3, Opts) -> livery_h3:start(Opts);
start_listener(_Name, _Opts) -> {error, unknown_adapter}.

-doc "Stop a single-protocol listener by adapter and handle.".
-spec stop_listener(
    {livery_h1, livery_h1:listener()}
    | {livery_h2, livery_h2:listener()}
    | {livery_h3, livery_h3:listener()}
    | term()
) -> ok | {error, term()}.
stop_listener({livery_h1, Ref}) -> livery_h1:stop(Ref);
stop_listener({livery_h2, Ref}) -> livery_h2:stop(Ref);
stop_listener({livery_h3, Ref}) -> livery_h3:stop(Ref);
stop_listener(_) -> {error, unknown_listener}.

-doc """
Start the full service: H3 on UDP, H2 on TLS, H1 on TCP, sharing
one middleware stack and handler, optionally advertising Alt-Svc
on H1 and H2 responses.

See `livery_service:start_link/1` for the opts shape.
""".
-spec start_service(livery_service:service_opts()) ->
    {ok, pid()} | {error, term()}.
start_service(Opts) ->
    livery_service:start_link(Opts).

-doc "Stop a running service by pid (immediate; cuts off in-flight).".
-spec stop_service(pid()) -> ok.
stop_service(Pid) when is_pid(Pid) ->
    livery_service:stop(Pid).

-doc "Gracefully drain and stop a service. See `livery_drain:drain/1`.".
-spec drain(pid()) -> ok | {error, timeout}.
drain(Pid) when is_pid(Pid) ->
    livery_drain:drain(Pid).

-doc """
Gracefully drain and stop a service: stop accepting new
connections, wait up to the timeout for in-flight requests to
finish, then stop. See `livery_drain:drain/2`.
""".
-spec drain(pid(), livery_drain:opts()) -> ok | {error, timeout}.
drain(Pid, Opts) when is_pid(Pid) ->
    livery_drain:drain(Pid, Opts).

-doc """
List the bound ports of a running service, keyed by protocol.

Returns a map containing only the protocols that were configured.
""".
-spec which_listeners(pid()) -> #{h1 | h2 | h3 => inet:port_number()}.
which_listeners(Pid) when is_pid(Pid) ->
    livery_service:which_listeners(Pid).

%%====================================================================
%% Router dispatch
%%====================================================================

-doc """
Turn a compiled router into a request handler.

Returns a `fun((livery_req:req()) -> livery_resp:resp())` that
matches the request's method and path against `Router`, sets the
captured path parameters as bindings, and invokes the matched
route handler. Unmatched paths get `404`; a path that exists for a
different method gets `405` with an `Allow` header.

Pass the result as the `handler` for a listener, or give the
router directly to `start_service/1` (which calls this for you).
""".
-spec router_handler(livery_router:router()) ->
    fun((livery_req:req()) -> livery_resp:resp()).
router_handler(Router) ->
    router_handler(Router, #{}).

-doc """
`router_handler/1` with fallbacks.

`Opts` may set `not_found => fun((Req) -> Resp)` and
`method_not_allowed => fun((Req, [Method]) -> Resp)` to override the
default `404`/`405` responses.
""".
-spec router_handler(livery_router:router(), map()) ->
    fun((livery_req:req()) -> livery_resp:resp()).
router_handler(Router, Opts) ->
    NotFound = maps:get(not_found, Opts, fun default_not_found/1),
    NotAllowed = maps:get(
        method_not_allowed,
        Opts,
        fun default_method_not_allowed/2
    ),
    fun(Req) ->
        Method = livery_req:method(Req),
        Path = livery_req:path(Req),
        case livery_router:match(Method, Path, Router) of
            {ok, Handler, Bindings, Meta} ->
                Req1 = livery_req:set_bindings(Bindings, Req),
                %% A route may carry its own middleware stack under
                %% `Meta`'s `middleware' key; it runs inside any
                %% service-level stack, just for this route.
                dispatch(route_stack(Meta), Handler, Req1);
            {error, not_found} ->
                NotFound(Req);
            {error, {method_not_allowed, Methods}} ->
                NotAllowed(Req, Methods)
        end
    end.

-spec route_stack(term()) -> livery_middleware:stack().
route_stack(Meta) when is_map(Meta) ->
    maps:get(middleware, Meta, []);
route_stack(_Meta) ->
    [].

-spec default_not_found(livery_req:req()) -> livery_resp:resp().
default_not_found(_Req) ->
    livery_resp:text(404, <<"not found">>).

-spec default_method_not_allowed(
    livery_req:req(),
    [binary() | '_']
) -> livery_resp:resp().
default_method_not_allowed(_Req, Methods) ->
    Allow = [M || M <- Methods, M =/= '_'],
    Resp = livery_resp:text(405, <<"method not allowed">>),
    livery_resp:with_header(
        <<"allow">>,
        iolist_to_binary(lists:join(<<", ">>, Allow)),
        Resp
    ).

%%====================================================================
%% Dispatch and emit
%%====================================================================

-doc """
Run a middleware stack and handler against a request value.

Pure dispatch: returns the `#livery_resp{}` value produced by the
pipeline. Adapters generally invoke this from a per-request process
and then call `emit/3` to write the response back to the wire.
""".
-spec dispatch(
    livery_middleware:stack(),
    livery_middleware:handler(),
    livery_req:req()
) -> livery_resp:resp().
dispatch(Stack, Handler, Req) ->
    livery_middleware:run(Stack, Handler, Req).

-doc """
Walk a response body variant and drive the adapter callbacks.

Called once a handler has returned. The walker emits status and
headers, then iterates the body variant (`full`, `chunked`, `sse`,
`file`, `empty`, or `upgrade`) into `Adapter:send_headers/4`,
`Adapter:send_data/3`, and `Adapter:send_trailers/2`. Errors from
the adapter are propagated by stopping the walk and returning the
error tuple.

A `{file, Path, Range}` body is streamed from the filesystem in
64 KiB chunks. `Content-Length` is set from the resolved segment
(unless the handler already set it); a byte range adds a
`Content-Range` header. A missing file emits `404`, an
unsatisfiable range emits `416`.
""".
-spec emit(module(), livery_adapter:stream(), livery_resp:resp()) ->
    ok | {error, term()}.
emit(Adapter, Stream, #livery_resp{} = Resp) ->
    Status = livery_resp:status(Resp),
    Headers = livery_resp:headers(Resp),
    Body = livery_resp:body(Resp),
    Trailers = livery_resp:trailers(Resp),
    emit_body(Adapter, Stream, Status, Headers, Body, Trailers).

emit_body(_Adapter, _Stream, _Status, _Hs, taken_over, _Trailers) ->
    %% Stream/socket was handed off (e.g. via livery_ws:upgrade/3).
    %% The adapter no longer owns it; nothing more to emit.
    ok;
emit_body(Adapter, Stream, Status, Hs, empty, _Trailers) ->
    Adapter:send_headers(Stream, Status, Hs, #{end_stream => true});
emit_body(Adapter, Stream, Status, Hs, {full, IoData}, Trailers) ->
    HasTrailers = Trailers =/= undefined,
    case iolist_size(IoData) of
        0 when not HasTrailers ->
            Adapter:send_headers(Stream, Status, Hs, #{end_stream => true});
        0 ->
            case Adapter:send_headers(Stream, Status, Hs, #{end_stream => false}) of
                ok -> emit_trailers(Adapter, Stream, Trailers);
                Other -> Other
            end;
        _ ->
            CanCoalesce =
                not HasTrailers andalso
                    erlang:function_exported(Adapter, send_full, 5),
            case CanCoalesce of
                true ->
                    %% Coalesce headers + body into one adapter call (and
                    %% one socket write) when the adapter supports it.
                    Adapter:send_full(Stream, Status, Hs, IoData, #{end_stream => true});
                false ->
                    emit_full_granular(Adapter, Stream, Status, Hs, IoData, Trailers)
            end
    end;
emit_body(Adapter, Stream, Status, Hs, {chunked, Producer}, Trailers) ->
    case Adapter:send_headers(Stream, Status, Hs, #{end_stream => false}) of
        ok ->
            Emit = fun(Chunk) ->
                Adapter:send_data(Stream, Chunk, #{end_stream => false})
            end,
            finish_stream(Adapter, Stream, Producer(Emit), Trailers);
        Other ->
            Other
    end;
emit_body(Adapter, Stream, Status, Hs, {sse, Producer}, Trailers) ->
    case Adapter:send_headers(Stream, Status, Hs, #{end_stream => false}) of
        ok ->
            Emit = fun(Event) ->
                Adapter:send_data(
                    Stream,
                    sse_frame(Event),
                    #{end_stream => false}
                )
            end,
            finish_stream(Adapter, Stream, Producer(Emit), Trailers);
        Other ->
            Other
    end;
emit_body(Adapter, Stream, Status, Hs, {file, Path, Range}, Trailers) ->
    case file_segment(Path, Range) of
        {error, enoent} ->
            Adapter:send_headers(Stream, 404, [], #{end_stream => true});
        {error, range_not_satisfiable} ->
            Adapter:send_headers(Stream, 416, [], #{end_stream => true});
        {error, Reason} ->
            Adapter:reset(Stream, Reason),
            {error, Reason};
        {ok, Offset, Length, FileSize} ->
            {Status1, Hs1} = file_headers(
                Status,
                Hs,
                Offset,
                Length,
                FileSize,
                Range
            ),
            HasTrailers = Trailers =/= undefined,
            case Length of
                0 when not HasTrailers ->
                    Adapter:send_headers(
                        Stream,
                        Status1,
                        Hs1,
                        #{end_stream => true}
                    );
                0 ->
                    case
                        Adapter:send_headers(
                            Stream,
                            Status1,
                            Hs1,
                            #{end_stream => false}
                        )
                    of
                        ok -> emit_trailers(Adapter, Stream, Trailers);
                        Other -> Other
                    end;
                _ ->
                    case
                        Adapter:send_headers(
                            Stream,
                            Status1,
                            Hs1,
                            #{end_stream => false}
                        )
                    of
                        ok ->
                            stream_file(
                                Adapter,
                                Stream,
                                Path,
                                Offset,
                                Length,
                                Trailers
                            );
                        Other ->
                            Other
                    end
            end
    end;
emit_body(Adapter, Stream, _Status, _Hs, {upgrade, _Kind, _State}, _Trailers) ->
    %% Upgrades are handled at the adapter level (livery_ws, livery_wt).
    Adapter:reset(Stream, upgrade_not_handled_at_emit),
    {error, not_implemented}.

%% Granular full-body emit: separate headers then body, closing the
%% stream after the body unless trailers follow. Used when the adapter
%% does not export the coalesced `send_full/5'.
emit_full_granular(Adapter, Stream, Status, Hs, IoData, Trailers) ->
    case Adapter:send_headers(Stream, Status, Hs, #{end_stream => false}) of
        ok ->
            EndStream = Trailers =:= undefined,
            case Adapter:send_data(Stream, IoData, #{end_stream => EndStream}) of
                ok -> emit_trailers(Adapter, Stream, Trailers);
                Other -> Other
            end;
        Other ->
            Other
    end.

emit_trailers(_Adapter, _Stream, undefined) ->
    ok;
emit_trailers(Adapter, Stream, Trailers) when is_list(Trailers) ->
    Adapter:send_trailers(Stream, Trailers);
emit_trailers(Adapter, Stream, Fun) when is_function(Fun, 0) ->
    Adapter:send_trailers(Stream, Fun()).

%% Close a chunked/SSE stream once its producer returns. A producer
%% that reports a failed send (the client is gone) short-circuits the
%% terminal write and surfaces the error.
finish_stream(_Adapter, _Stream, {error, _} = Err, _Trailers) ->
    Err;
finish_stream(Adapter, Stream, _ProducerResult, Trailers) ->
    close_stream(Adapter, Stream, Trailers).

close_stream(Adapter, Stream, undefined) ->
    Adapter:send_data(Stream, <<>>, #{end_stream => true});
close_stream(Adapter, Stream, Trailers) ->
    emit_trailers(Adapter, Stream, Trailers).

%%====================================================================
%% File emission
%%====================================================================

-define(FILE_CHUNK_SIZE, 65536).

-type trailers() ::
    undefined
    | [{binary(), binary()}]
    | fun(() -> [{binary(), binary()}]).

-spec file_segment(
    file:name_all(),
    undefined | {non_neg_integer(), non_neg_integer() | eof}
) ->
    {ok, non_neg_integer(), non_neg_integer(), non_neg_integer()}
    | {error, enoent | not_a_regular_file | range_not_satisfiable}.
file_segment(Path, Range) ->
    case filelib:is_regular(Path) of
        true ->
            resolve_range(Range, filelib:file_size(Path));
        false ->
            case filelib:is_file(Path) of
                true -> {error, not_a_regular_file};
                false -> {error, enoent}
            end
    end.

-spec resolve_range(
    undefined | {non_neg_integer(), non_neg_integer() | eof},
    non_neg_integer()
) ->
    {ok, non_neg_integer(), non_neg_integer(), non_neg_integer()}
    | {error, range_not_satisfiable}.
resolve_range(undefined, Size) ->
    {ok, 0, Size, Size};
resolve_range({Offset, eof}, Size) when
    is_integer(Offset), Offset >= 0, Offset =< Size
->
    {ok, Offset, Size - Offset, Size};
resolve_range({Offset, Length}, Size) when
    is_integer(Offset),
    is_integer(Length),
    Offset >= 0,
    Length >= 0,
    Offset =< Size
->
    {ok, Offset, min(Length, Size - Offset), Size};
resolve_range(_Range, _Size) ->
    {error, range_not_satisfiable}.

-spec file_headers(
    100..599,
    [{binary(), iodata()}],
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    undefined | {non_neg_integer(), non_neg_integer() | eof}
) ->
    {100..599, [{binary(), iodata()}]}.
file_headers(Status, Hs, _Offset, Length, _FileSize, undefined) ->
    {Status, set_content_length(Hs, Length)};
file_headers(Status, Hs, _Offset, 0, _FileSize, _Range) ->
    {Status, set_content_length(Hs, 0)};
file_headers(Status, Hs, Offset, Length, FileSize, _Range) ->
    Hs1 = set_content_length(Hs, Length),
    Last = Offset + Length - 1,
    CR = iolist_to_binary([
        <<"bytes ">>,
        integer_to_binary(Offset),
        <<"-">>,
        integer_to_binary(Last),
        <<"/">>,
        integer_to_binary(FileSize)
    ]),
    {Status, [{<<"content-range">>, CR} | Hs1]}.

-spec set_content_length([{binary(), iodata()}], non_neg_integer()) ->
    [{binary(), iodata()}].
set_content_length(Hs, Length) ->
    case has_header(<<"content-length">>, Hs) of
        true -> Hs;
        false -> [{<<"content-length">>, integer_to_binary(Length)} | Hs]
    end.

-spec has_header(binary(), [{binary(), iodata()}]) -> boolean().
has_header(Name, Hs) ->
    Lower = string:lowercase(Name),
    lists:any(fun({K, _}) -> string:lowercase(K) =:= Lower end, Hs).

-spec stream_file(
    module(),
    livery_adapter:stream(),
    file:name_all(),
    non_neg_integer(),
    non_neg_integer(),
    trailers()
) -> ok | {error, term()}.
stream_file(Adapter, Stream, Path, Offset, Length, Trailers) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try
                {ok, _} = file:position(Fd, Offset),
                send_file_chunks(Adapter, Stream, Fd, Length, Trailers)
            after
                file:close(Fd)
            end;
        {error, Reason} ->
            Adapter:reset(Stream, Reason),
            {error, Reason}
    end.

-spec send_file_chunks(
    module(),
    livery_adapter:stream(),
    file:io_device(),
    non_neg_integer(),
    trailers()
) ->
    ok | {error, term()}.
send_file_chunks(Adapter, Stream, Fd, Remaining, Trailers) ->
    HasTrailers = Trailers =/= undefined,
    case file:read(Fd, min(Remaining, ?FILE_CHUNK_SIZE)) of
        eof ->
            close_stream(Adapter, Stream, Trailers);
        {ok, Data} ->
            Rest = Remaining - byte_size(Data),
            Last = Rest =< 0,
            EndStream = Last andalso not HasTrailers,
            case Adapter:send_data(Stream, Data, #{end_stream => EndStream}) of
                ok when Last andalso HasTrailers ->
                    emit_trailers(Adapter, Stream, Trailers);
                ok when Last ->
                    ok;
                ok ->
                    send_file_chunks(Adapter, Stream, Fd, Rest, Trailers);
                Other ->
                    Other
            end;
        {error, Reason} ->
            Adapter:reset(Stream, Reason),
            {error, Reason}
    end.

%%====================================================================
%% SSE framing (RFC text/event-stream)
%%====================================================================

-spec sse_frame(map() | iodata()) -> iodata().
sse_frame(#{data := Data} = E) ->
    Event = maps:get(event, E, undefined),
    Id = maps:get(id, E, undefined),
    Retry = maps:get(retry, E, undefined),
    [
        maybe_field(<<"event">>, Event),
        maybe_field(<<"id">>, Id),
        maybe_field(<<"retry">>, Retry),
        data_lines(Data),
        <<"\n">>
    ];
sse_frame(IoData) ->
    [<<"data: ">>, IoData, <<"\n\n">>].

maybe_field(_, undefined) -> [];
maybe_field(Name, Value) -> [Name, <<": ">>, to_iodata(Value), <<"\n">>].

data_lines(B) when is_binary(B) ->
    [<<"data: ">>, B, <<"\n">>];
data_lines(L) when is_list(L) ->
    [<<"data: ">>, L, <<"\n">>].

to_iodata(B) when is_binary(B) -> B;
to_iodata(L) when is_list(L) -> L;
to_iodata(A) when is_atom(A) -> atom_to_binary(A);
to_iodata(I) when is_integer(I) -> integer_to_binary(I).
