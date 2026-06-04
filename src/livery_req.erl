-module(livery_req).
-moduledoc """
Request accessors and builders.

Requests flow as immutable `#livery_req{}` values. Adapters build
the initial value from protocol-specific events; middleware and
handlers read it via the helpers in this module and can derive a
new value for the next stage using the setters.
""".

-include("livery.hrl").

-export([
    new/1,

    protocol/1,
    method/1,
    scheme/1,
    authority/1,
    path/1,
    query/1,
    peer/1,
    tls/1,
    adapter/1,
    stream/1,
    engine_pid/1,
    req_id/1,
    started_at/1,

    headers/1,
    header/2,
    header/3,
    headers_all/2,
    has_header/2,
    set_header/3,
    append_header/3,
    delete_header/2,

    bindings/1,
    binding/2,
    binding/3,
    set_bindings/2,

    body/1,
    set_body/2,

    meta/1,
    meta/2,
    meta/3,
    set_meta/3,

    config/1,
    config/2,
    config/3,

    set_req_id/2,

    on_disconnect/2,
    disconnect_tag/0
]).

-export_type([req/0]).

-type req() :: #livery_req{}.
-type header_name() :: binary().
-type header_value() :: binary().

-doc """
Construct a request from a map of fields.

Intended for adapters. Unspecified fields fall back to defaults on
the record.
""".
-spec new(map()) -> req().
new(Fields) when is_map(Fields) ->
    maps:fold(fun set_field/3, #livery_req{}, Fields).

-spec set_field(atom(), term(), req()) -> req().
set_field(protocol, V, R) -> R#livery_req{protocol = V};
set_field(method, V, R) -> R#livery_req{method = V};
set_field(scheme, V, R) -> R#livery_req{scheme = V};
set_field(authority, V, R) -> R#livery_req{authority = V};
set_field(path, V, R) -> R#livery_req{path = V};
set_field(raw_query, V, R) -> R#livery_req{raw_query = V};
set_field(bindings, V, R) -> R#livery_req{bindings = V};
set_field(headers, V, R) -> R#livery_req{headers = normalize_headers(V)};
set_field(peer, V, R) -> R#livery_req{peer = V};
set_field(tls, V, R) -> R#livery_req{tls = V};
set_field(body, V, R) -> R#livery_req{body = V};
set_field(adapter, V, R) -> R#livery_req{adapter = V};
set_field(stream, V, R) -> R#livery_req{stream = V};
set_field(engine_pid, V, R) -> R#livery_req{engine_pid = V};
set_field(notifier_pid, V, R) -> R#livery_req{notifier_pid = V};
set_field(disc_ref, V, R) -> R#livery_req{disc_ref = V};
set_field(req_id, V, R) -> R#livery_req{req_id = V};
set_field(started_at, V, R) -> R#livery_req{started_at = V};
set_field(meta, V, R) -> R#livery_req{meta = V};
set_field(config, V, R) -> R#livery_req{config = V};
set_field(Key, _V, _R) -> error({badarg, Key}).

%%====================================================================
%% Basic accessors
%%====================================================================

-doc "Wire protocol of the request: `h1`, `h2`, or `h3`.".
-spec protocol(req()) -> h1 | h2 | h3.
protocol(#livery_req{protocol = V}) -> V.

-doc "HTTP method, uppercase binary (e.g. `<<\"GET\">>`).".
-spec method(req()) -> binary().
method(#livery_req{method = V}) -> V.

-doc "URL scheme: typically `<<\"http\">>` or `<<\"https\">>`.".
-spec scheme(req()) -> binary().
scheme(#livery_req{scheme = V}) -> V.

-doc "Authority (host:port), as the client sent it.".
-spec authority(req()) -> binary().
authority(#livery_req{authority = V}) -> V.

-doc "Decoded path portion of the request URI.".
-spec path(req()) -> binary().
path(#livery_req{path = V}) -> V.

-doc "Raw query string (everything after `?`, no leading `?`).".
-spec query(req()) -> binary().
query(#livery_req{raw_query = V}) -> V.

-doc "Peer address and port if the adapter knows it.".
-spec peer(req()) -> {inet:ip_address(), inet:port_number()} | undefined.
peer(#livery_req{peer = V}) -> V.

-doc "TLS info map for HTTPS requests; `undefined` for plain HTTP.".
-spec tls(req()) -> undefined | map().
tls(#livery_req{tls = V}) -> V.

-doc "Adapter module that produced this request.".
-spec adapter(req()) -> module() | undefined.
adapter(#livery_req{adapter = V}) -> V.

-doc "Adapter-specific stream handle.".
-spec stream(req()) -> term().
stream(#livery_req{stream = V}) -> V.

-doc "Engine pid for this connection (adapter-specific).".
-spec engine_pid(req()) -> pid() | undefined.
engine_pid(#livery_req{engine_pid = V}) -> V.

-doc "Request id set by `livery_request_id` or user code.".
-spec req_id(req()) -> binary().
req_id(#livery_req{req_id = V}) -> V.

-doc "Monotonic-time timestamp set by `livery_req_proc` on entry.".
-spec started_at(req()) -> integer() | undefined.
started_at(#livery_req{started_at = V}) -> V.

%%====================================================================
%% Headers
%%====================================================================

-doc "All request headers in wire order, names lowercased.".
-spec headers(req()) -> [{header_name(), header_value()}].
headers(#livery_req{headers = V}) -> V.

-doc "First value for a header, or `undefined`.".
-spec header(header_name(), req()) -> header_value() | undefined.
header(Name, Req) -> header(Name, Req, undefined).

-doc "First value for a header, falling back to `Default`.".
-spec header(header_name(), req(), Default) -> header_value() | Default.
header(Name, #livery_req{headers = Hs}, Default) ->
    LName = lowercase(Name),
    case lists:keyfind(LName, 1, Hs) of
        {_, V} -> V;
        false -> Default
    end.

-doc """
Return all values associated with a header name.

HTTP header names may appear more than once in H1 and H2; this
returns them in wire order.
""".
-spec headers_all(header_name(), req()) -> [header_value()].
headers_all(Name, #livery_req{headers = Hs}) ->
    LName = lowercase(Name),
    [V || {N, V} <- Hs, N =:= LName].

-doc "True if the header is present at least once.".
-spec has_header(header_name(), req()) -> boolean().
has_header(Name, #livery_req{headers = Hs}) ->
    LName = lowercase(Name),
    lists:keyfind(LName, 1, Hs) /= false.

-doc "Replace (or insert) a header.".
-spec set_header(header_name(), header_value(), req()) -> req().
set_header(Name, Value, #livery_req{headers = Hs} = Req) ->
    LName = lowercase(Name),
    Hs1 = lists:keystore(LName, 1, delete_all(LName, Hs), {LName, Value}),
    Req#livery_req{headers = Hs1}.

-doc "Append a header even if one with this name exists.".
-spec append_header(header_name(), header_value(), req()) -> req().
append_header(Name, Value, #livery_req{headers = Hs} = Req) ->
    Req#livery_req{headers = Hs ++ [{lowercase(Name), Value}]}.

-doc "Remove every header with this name.".
-spec delete_header(header_name(), req()) -> req().
delete_header(Name, #livery_req{headers = Hs} = Req) ->
    Req#livery_req{headers = delete_all(lowercase(Name), Hs)}.

%%====================================================================
%% Router bindings
%%====================================================================

-doc "Map of path parameters captured by the router.".
-spec bindings(req()) -> #{binary() => binary()}.
bindings(#livery_req{bindings = V}) -> V.

-doc "Look up a binding, or `undefined`.".
-spec binding(binary(), req()) -> binary() | undefined.
binding(Name, Req) -> binding(Name, Req, undefined).

-doc "Look up a binding, falling back to `Default`.".
-spec binding(binary(), req(), Default) -> binary() | Default.
binding(Name, #livery_req{bindings = Bs}, Default) ->
    maps:get(Name, Bs, Default).

-doc "Replace the bindings map (used by the router).".
-spec set_bindings(#{binary() => binary()}, req()) -> req().
set_bindings(Bs, Req) when is_map(Bs) ->
    Req#livery_req{bindings = Bs}.

%%====================================================================
%% Body
%%====================================================================

-doc """
Body shape: `empty`, `{buffered, IoData}`, or `{stream, Reader}`.

The `Reader` is opaque; drain it with `livery_body:read/2`.
""".
-spec body(req()) -> empty | {buffered, iodata()} | {stream, term()}.
body(#livery_req{body = V}) -> V.

-doc "Replace the body field on the request.".
-spec set_body(empty | {buffered, iodata()} | {stream, term()}, req()) -> req().
set_body(Body, Req) ->
    Req#livery_req{body = Body}.

%%====================================================================
%% Middleware metadata
%%====================================================================

-doc "Full meta map.".
-spec meta(req()) -> map().
meta(#livery_req{meta = V}) -> V.

-doc "Look up a meta key, or `undefined`.".
-spec meta(term(), req()) -> term() | undefined.
meta(Key, Req) -> meta(Key, Req, undefined).

-doc "Look up a meta key, falling back to `Default`.".
-spec meta(term(), req(), Default) -> term() | Default.
meta(Key, #livery_req{meta = M}, Default) ->
    maps:get(Key, M, Default).

-doc "Set a meta key. Used by middleware to thread state to handlers.".
-spec set_meta(term(), term(), req()) -> req().
set_meta(Key, Value, #livery_req{meta = M} = Req) ->
    Req#livery_req{meta = maps:put(Key, Value, M)}.

%%====================================================================
%% Service config
%%====================================================================

-doc """
The service config: the value passed once at listener or service start
(`config => ...`), the same for every request. Use it for shared handles
and settings (a DB pool, a cache, a config map). `undefined` if none was
set. Unlike `meta`, it is read-only and not per-request.
""".
-spec config(req()) -> term().
config(#livery_req{config = C}) -> C.

-doc "Look up a key in a map config, or `undefined`.".
-spec config(term(), req()) -> term() | undefined.
config(Key, Req) -> config(Key, Req, undefined).

-doc "Look up a key in a map config, falling back to `Default`.".
-spec config(term(), req(), Default) -> term() | Default.
config(Key, #livery_req{config = C}, Default) when is_map(C) ->
    maps:get(Key, C, Default);
config(_Key, #livery_req{}, Default) ->
    Default.

-doc "Set the request id field. Used by `livery_request_id`.".
-spec set_req_id(binary(), req()) -> req().
set_req_id(Id, Req) when is_binary(Id) ->
    Req#livery_req{req_id = Id}.

%%====================================================================
%% Client disconnect
%%====================================================================

-doc """
Register a cancel callback to run when the client disconnects.

`Fun` is a 0-arity function (e.g. `fun() -> my_llm:cancel(Ref) end`).
If the client resets the stream or closes the connection before the
request finishes, `Fun` is run exactly once in a fresh process, even
if the handler is blocked in a NIF. It never runs on normal
completion. Returns `ok` immediately; a no-op on adapters without a
real connection (e.g. the test adapter).

A handler that runs its own `receive` loop can instead match the
`{livery_disconnect, _Ref, _Reason}` message delivered to it; see
`disconnect_tag/0`.
""".
-spec on_disconnect(req(), fun(() -> term())) -> ok.
on_disconnect(#livery_req{notifier_pid = undefined}, _Fun) ->
    ok;
on_disconnect(#livery_req{notifier_pid = Pid, disc_ref = Ref}, Fun) when
    is_pid(Pid), is_reference(Ref), is_function(Fun, 0)
->
    Pid ! {livery_on_disconnect, Ref, Fun},
    ok;
on_disconnect(#livery_req{}, _Fun) ->
    ok.

-doc """
The tag of the disconnect message delivered to a request worker.

A handler in a `receive` loop matches
`{livery_disconnect, _Ref, _Reason}`. This helper returns the tag
atom (`livery_disconnect`) for guard-style matching.
""".
-spec disconnect_tag() -> livery_disconnect.
disconnect_tag() ->
    livery_disconnect.

%%====================================================================
%% Helpers
%%====================================================================

-spec normalize_headers([{header_name(), header_value()}]) ->
    [{header_name(), header_value()}].
normalize_headers(Hs) ->
    [{lowercase(N), V} || {N, V} <- Hs].

-spec lowercase(binary()) -> binary().
lowercase(Bin) when is_binary(Bin) ->
    %% Fast path: ASCII-only header names. Fall back to string:lowercase
    %% for the rare cases where a header name carries non-ASCII bytes.
    case is_lower_ascii(Bin) of
        true -> Bin;
        false -> iolist_to_binary(string:lowercase(Bin))
    end.

-spec is_lower_ascii(binary()) -> boolean().
is_lower_ascii(<<>>) -> true;
is_lower_ascii(<<C, Rest/binary>>) when C >= $a, C =< $z -> is_lower_ascii(Rest);
is_lower_ascii(<<C, Rest/binary>>) when C >= $0, C =< $9 -> is_lower_ascii(Rest);
is_lower_ascii(<<$-, Rest/binary>>) -> is_lower_ascii(Rest);
is_lower_ascii(<<$:, Rest/binary>>) -> is_lower_ascii(Rest);
is_lower_ascii(_) -> false.

-spec delete_all(binary(), [{binary(), term()}]) -> [{binary(), term()}].
delete_all(Key, L) ->
    [KV || {K, _} = KV <- L, K =/= Key].
