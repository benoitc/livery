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
    which_listeners/1,
    router_handler/1,
    router_handler/2,
    dispatch/3,
    emit/3
]).

%%====================================================================
%% Service lifecycle (stubs until livery_service lands)
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
start_listener(_Name, _Opts) ->
    {error, unknown_adapter}.

-doc "Stop a single-protocol listener by adapter and handle.".
-spec stop_listener({livery_h1, livery_h1:listener()}
                  | {livery_h2, livery_h2:listener()}
                  | {livery_h3, livery_h3:listener()}
                  | term()) -> ok | {error, term()}.
stop_listener({livery_h1, Ref}) -> livery_h1:stop(Ref);
stop_listener({livery_h2, Ref}) -> livery_h2:stop(Ref);
stop_listener({livery_h3, Ref}) -> livery_h3:stop(Ref);
stop_listener(_) ->
    {error, unknown_listener}.

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

-doc "Stop a running service by pid.".
-spec stop_service(pid()) -> ok.
stop_service(Pid) when is_pid(Pid) ->
    livery_service:stop(Pid).

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
    NotAllowed = maps:get(method_not_allowed, Opts,
                          fun default_method_not_allowed/2),
    fun(Req) ->
        Method = livery_req:method(Req),
        Path = livery_req:path(Req),
        case livery_router:match(Method, Path, Router) of
            {ok, Handler, Bindings, _Meta} ->
                invoke_route(Handler, livery_req:set_bindings(Bindings, Req));
            {error, not_found} ->
                NotFound(Req);
            {error, {method_not_allowed, Methods}} ->
                NotAllowed(Req, Methods)
        end
    end.

-spec invoke_route(livery_middleware:handler(), livery_req:req()) ->
    livery_resp:resp().
invoke_route({M, F}, Req) when is_atom(M), is_atom(F) ->
    M:F(Req);
invoke_route(Fun, Req) when is_function(Fun, 1) ->
    Fun(Req).

-spec default_not_found(livery_req:req()) -> livery_resp:resp().
default_not_found(_Req) ->
    livery_resp:text(404, <<"not found">>).

-spec default_method_not_allowed(livery_req:req(),
                                 [binary() | '_']) -> livery_resp:resp().
default_method_not_allowed(_Req, Methods) ->
    Allow = [M || M <- Methods, M =/= '_'],
    Resp = livery_resp:text(405, <<"method not allowed">>),
    livery_resp:with_header(<<"allow">>,
        iolist_to_binary(lists:join(<<", ">>, Allow)), Resp).

%%====================================================================
%% Dispatch and emit
%%====================================================================

-doc """
Run a middleware stack and handler against a request value.

Pure dispatch: returns the `#livery_resp{}` value produced by the
pipeline. Adapters generally invoke this from a per-request process
and then call `emit/3` to write the response back to the wire.
""".
-spec dispatch(livery_middleware:stack(),
               livery_middleware:handler(),
               livery_req:req()) -> livery_resp:resp().
dispatch(Stack, Handler, Req) ->
    livery_middleware:run(Stack, Handler, Req).

-doc """
Walk a response body variant and drive the adapter callbacks.

Called once a handler has returned. The walker emits status and
headers, then iterates the body variant (`full`, `chunked`, `sse`,
`empty`, or upgrade/file placeholders) into
`Adapter:send_headers/4`, `Adapter:send_data/3`, and
`Adapter:send_trailers/2`. Errors from the adapter are propagated
by stopping the walk and returning the error tuple.
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
                ok    -> emit_trailers(Adapter, Stream, Trailers);
                Other -> Other
            end;
        _ ->
            case Adapter:send_headers(Stream, Status, Hs, #{end_stream => false}) of
                ok ->
                    EndStream = not HasTrailers,
                    case Adapter:send_data(Stream, IoData, #{end_stream => EndStream}) of
                        ok    -> emit_trailers(Adapter, Stream, Trailers);
                        Other -> Other
                    end;
                Other -> Other
            end
    end;
emit_body(Adapter, Stream, Status, Hs, {chunked, Producer}, Trailers) ->
    case Adapter:send_headers(Stream, Status, Hs, #{end_stream => false}) of
        ok ->
            Emit = fun(Chunk) ->
                Adapter:send_data(Stream, Chunk, #{end_stream => false})
            end,
            _ = Producer(Emit),
            close_stream(Adapter, Stream, Trailers);
        Other -> Other
    end;
emit_body(Adapter, Stream, Status, Hs, {sse, Producer}, Trailers) ->
    case Adapter:send_headers(Stream, Status, Hs, #{end_stream => false}) of
        ok ->
            Emit = fun(Event) ->
                Adapter:send_data(Stream, sse_frame(Event),
                                  #{end_stream => false})
            end,
            _ = Producer(Emit),
            close_stream(Adapter, Stream, Trailers);
        Other -> Other
    end;
emit_body(Adapter, Stream, _Status, _Hs, {file, _Path, _Range}, _Trailers) ->
    %% File emission lands once the H1 adapter wires sendfile.
    Adapter:reset(Stream, file_emission_not_implemented),
    {error, not_implemented};
emit_body(Adapter, Stream, _Status, _Hs, {upgrade, _Kind, _State}, _Trailers) ->
    %% Upgrades are handled at the adapter level (livery_ws, livery_wt).
    Adapter:reset(Stream, upgrade_not_handled_at_emit),
    {error, not_implemented}.

emit_trailers(_Adapter, _Stream, undefined) ->
    ok;
emit_trailers(Adapter, Stream, Trailers) when is_list(Trailers) ->
    Adapter:send_trailers(Stream, Trailers);
emit_trailers(Adapter, Stream, Fun) when is_function(Fun, 0) ->
    Adapter:send_trailers(Stream, Fun()).

close_stream(Adapter, Stream, undefined) ->
    Adapter:send_data(Stream, <<>>, #{end_stream => true});
close_stream(Adapter, Stream, Trailers) ->
    emit_trailers(Adapter, Stream, Trailers).

%%====================================================================
%% SSE framing (RFC text/event-stream)
%%====================================================================

-spec sse_frame(map() | iodata()) -> iodata().
sse_frame(#{data := Data} = E) ->
    Event = maps:get(event, E, undefined),
    Id = maps:get(id, E, undefined),
    Retry = maps:get(retry, E, undefined),
    [maybe_field(<<"event">>, Event),
     maybe_field(<<"id">>, Id),
     maybe_field(<<"retry">>, Retry),
     data_lines(Data),
     <<"\n">>];
sse_frame(IoData) ->
    [<<"data: ">>, IoData, <<"\n\n">>].

maybe_field(_, undefined) -> [];
maybe_field(Name, Value) ->
    [Name, <<": ">>, to_iodata(Value), <<"\n">>].

data_lines(B) when is_binary(B) ->
    [<<"data: ">>, B, <<"\n">>];
data_lines(L) when is_list(L) ->
    [<<"data: ">>, L, <<"\n">>].

to_iodata(B) when is_binary(B) -> B;
to_iodata(L) when is_list(L) -> L;
to_iodata(A) when is_atom(A) -> atom_to_binary(A);
to_iodata(I) when is_integer(I) -> integer_to_binary(I).
