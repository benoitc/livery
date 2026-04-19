%% @doc Request accessors and builders.
%%
%% Requests flow as immutable `#livery_req{}' values. Adapters build the
%% initial value from protocol-specific events; middleware and handlers
%% read it via the helpers in this module and can derive a new value for
%% the next stage using the setters.
-module(livery_req).

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
    set_meta/3
]).

-export_type([req/0]).

-type req() :: #livery_req{}.
-type header_name() :: binary().
-type header_value() :: binary().

%% @doc Construct a request from a map of fields.
%%
%% Intended for adapters. Unspecified fields fall back to defaults on
%% the record.
-spec new(map()) -> req().
new(Fields) when is_map(Fields) ->
    maps:fold(fun set_field/3, #livery_req{}, Fields).

-spec set_field(atom(), term(), req()) -> req().
set_field(protocol,    V, R) -> R#livery_req{protocol = V};
set_field(method,      V, R) -> R#livery_req{method = V};
set_field(scheme,      V, R) -> R#livery_req{scheme = V};
set_field(authority,   V, R) -> R#livery_req{authority = V};
set_field(path,        V, R) -> R#livery_req{path = V};
set_field(raw_query,   V, R) -> R#livery_req{raw_query = V};
set_field(bindings,    V, R) -> R#livery_req{bindings = V};
set_field(headers,     V, R) -> R#livery_req{headers = normalize_headers(V)};
set_field(peer,        V, R) -> R#livery_req{peer = V};
set_field(tls,         V, R) -> R#livery_req{tls = V};
set_field(body,        V, R) -> R#livery_req{body = V};
set_field(adapter,     V, R) -> R#livery_req{adapter = V};
set_field(stream,      V, R) -> R#livery_req{stream = V};
set_field(engine_pid,  V, R) -> R#livery_req{engine_pid = V};
set_field(req_id,      V, R) -> R#livery_req{req_id = V};
set_field(started_at,  V, R) -> R#livery_req{started_at = V};
set_field(meta,        V, R) -> R#livery_req{meta = V};
set_field(Key, _V, _R) -> error({badarg, Key}).

%%====================================================================
%% Basic accessors
%%====================================================================

-spec protocol(req()) -> h1 | h2 | h3.
protocol(#livery_req{protocol = V}) -> V.

-spec method(req()) -> binary().
method(#livery_req{method = V}) -> V.

-spec scheme(req()) -> binary().
scheme(#livery_req{scheme = V}) -> V.

-spec authority(req()) -> binary().
authority(#livery_req{authority = V}) -> V.

-spec path(req()) -> binary().
path(#livery_req{path = V}) -> V.

-spec query(req()) -> binary().
query(#livery_req{raw_query = V}) -> V.

-spec peer(req()) -> {inet:ip_address(), inet:port_number()} | undefined.
peer(#livery_req{peer = V}) -> V.

-spec tls(req()) -> undefined | map().
tls(#livery_req{tls = V}) -> V.

-spec adapter(req()) -> module() | undefined.
adapter(#livery_req{adapter = V}) -> V.

-spec stream(req()) -> term().
stream(#livery_req{stream = V}) -> V.

-spec engine_pid(req()) -> pid() | undefined.
engine_pid(#livery_req{engine_pid = V}) -> V.

-spec req_id(req()) -> binary().
req_id(#livery_req{req_id = V}) -> V.

-spec started_at(req()) -> integer() | undefined.
started_at(#livery_req{started_at = V}) -> V.

%%====================================================================
%% Headers
%%====================================================================

-spec headers(req()) -> [{header_name(), header_value()}].
headers(#livery_req{headers = V}) -> V.

-spec header(header_name(), req()) -> header_value() | undefined.
header(Name, Req) -> header(Name, Req, undefined).

-spec header(header_name(), req(), Default) -> header_value() | Default.
header(Name, #livery_req{headers = Hs}, Default) ->
    LName = lowercase(Name),
    case lists:keyfind(LName, 1, Hs) of
        {_, V} -> V;
        false  -> Default
    end.

%% @doc Return all values associated with a header name.
%%
%% HTTP header names may appear more than once in H1 and H2; this
%% returns them in wire order.
-spec headers_all(header_name(), req()) -> [header_value()].
headers_all(Name, #livery_req{headers = Hs}) ->
    LName = lowercase(Name),
    [V || {N, V} <- Hs, N =:= LName].

-spec has_header(header_name(), req()) -> boolean().
has_header(Name, #livery_req{headers = Hs}) ->
    LName = lowercase(Name),
    lists:keyfind(LName, 1, Hs) /= false.

%% @doc Replace (or insert) a header.
-spec set_header(header_name(), header_value(), req()) -> req().
set_header(Name, Value, #livery_req{headers = Hs} = Req) ->
    LName = lowercase(Name),
    Hs1 = lists:keystore(LName, 1, delete_all(LName, Hs), {LName, Value}),
    Req#livery_req{headers = Hs1}.

%% @doc Append a header even if one with this name exists.
-spec append_header(header_name(), header_value(), req()) -> req().
append_header(Name, Value, #livery_req{headers = Hs} = Req) ->
    Req#livery_req{headers = Hs ++ [{lowercase(Name), Value}]}.

-spec delete_header(header_name(), req()) -> req().
delete_header(Name, #livery_req{headers = Hs} = Req) ->
    Req#livery_req{headers = delete_all(lowercase(Name), Hs)}.

%%====================================================================
%% Router bindings
%%====================================================================

-spec bindings(req()) -> #{binary() => binary()}.
bindings(#livery_req{bindings = V}) -> V.

-spec binding(binary(), req()) -> binary() | undefined.
binding(Name, Req) -> binding(Name, Req, undefined).

-spec binding(binary(), req(), Default) -> binary() | Default.
binding(Name, #livery_req{bindings = Bs}, Default) ->
    maps:get(Name, Bs, Default).

-spec set_bindings(#{binary() => binary()}, req()) -> req().
set_bindings(Bs, Req) when is_map(Bs) ->
    Req#livery_req{bindings = Bs}.

%%====================================================================
%% Body
%%====================================================================

-spec body(req()) -> empty | {buffered, iodata()} | {stream, term()}.
body(#livery_req{body = V}) -> V.

-spec set_body(empty | {buffered, iodata()} | {stream, term()}, req()) -> req().
set_body(Body, Req) ->
    Req#livery_req{body = Body}.

%%====================================================================
%% Middleware metadata
%%====================================================================

-spec meta(req()) -> map().
meta(#livery_req{meta = V}) -> V.

-spec meta(term(), req()) -> term() | undefined.
meta(Key, Req) -> meta(Key, Req, undefined).

-spec meta(term(), req(), Default) -> term() | Default.
meta(Key, #livery_req{meta = M}, Default) ->
    maps:get(Key, M, Default).

-spec set_meta(term(), term(), req()) -> req().
set_meta(Key, Value, #livery_req{meta = M} = Req) ->
    Req#livery_req{meta = maps:put(Key, Value, M)}.

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
        true  -> Bin;
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
