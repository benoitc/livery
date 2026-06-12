-module(livery_resp).
-moduledoc """
Response constructors and accessors.

Handlers return an immutable `#livery_resp{}` value. The core
emits it onto the wire by walking the body variant and driving
the adapter's `send_headers`/`send_data`/`send_trailers` calls.
Response builders here are pure: they never touch sockets.

Most builders fix the status and headers up front. When the status
is not known until the first byte (admission control, lazy probing),
use `stream_deferred/1` to choose between streaming and a one-shot
error after the handler returns but before anything is written.
""".

-include("livery.hrl").

-export([
    new/2,
    new/3,

    status/1,
    headers/1,
    body/1,
    trailers/1,

    with_status/2,
    with_header/3,
    append_header/3,
    delete_header/2,
    with_trailers/2,
    with_body/2,
    with_etag/2,
    with_cache_control/2,

    text/2,
    text/3,
    html/2,
    html/3,
    json/2,
    json/3,

    empty/1,

    stream/3,
    stream_deferred/1,
    resolve_deferred/1,
    resolve_deferred/2,
    sse/2,
    sse/3,

    ndjson/2,
    ndjson/3,

    file/2,
    file/3,

    redirect/2,
    redirect/3,

    upgrade/2
]).

-export_type([resp/0, body/0, deferred_decision/0, cache_directive/0]).

-type cache_directive() ::
    no_cache
    | no_store
    | public
    | private
    | immutable
    | must_revalidate
    | proxy_revalidate
    | no_transform
    | {max_age, non_neg_integer()}
    | {s_maxage, non_neg_integer()}
    | {stale_while_revalidate, non_neg_integer()}
    | {stale_if_error, non_neg_integer()}.

-type resp() :: #livery_resp{}.
-type header_name() :: binary().
-type header_value() :: binary().
-type producer() :: fun((term()) -> ok | {error, term()}).
-type body() ::
    {full, iodata()}
    | {chunked, producer()}
    | {sse, producer()}
    | {deferred, fun(() -> deferred_decision())}
    | {file, file:name_all(), undefined | {non_neg_integer(), non_neg_integer() | eof}}
    | {upgrade, ws | wt, term()}
    | empty
    | taken_over.

%% A deferred response resolves to exactly one of these on first
%% emit, before any header is written. See `stream_deferred/1`.
-type deferred_decision() ::
    {stream, 100..599, [{header_name(), header_value()}], producer()}
    | {sse, 100..599, [{header_name(), header_value()}], producer()}
    | {ndjson, 100..599, [{header_name(), header_value()}], producer()}
    | {full, 100..599, [{header_name(), header_value()}], iodata()}.

%%====================================================================
%% Construction
%%====================================================================

-doc "Build a response with the given status and headers, no body.".
-spec new(100..599, [{header_name(), header_value()}]) -> resp().
new(Status, Headers) ->
    new(Status, Headers, {full, <<>>}).

-doc "Build a response with status, headers, and a body variant.".
-spec new(100..599, [{header_name(), header_value()}], body()) -> resp().
new(Status, Headers, Body) ->
    #livery_resp{
        status = Status,
        headers = normalize_headers(Headers),
        body = Body
    }.

%%====================================================================
%% Basic accessors and mutators
%%====================================================================

-spec status(resp()) -> 100..599.
status(#livery_resp{status = S}) -> S.

-spec headers(resp()) -> [{header_name(), header_value()}].
headers(#livery_resp{headers = H}) -> H.

-spec body(resp()) -> body().
body(#livery_resp{body = B}) -> B.

-spec trailers(resp()) ->
    undefined
    | [{header_name(), header_value()}]
    | fun(() -> [{header_name(), header_value()}]).
trailers(#livery_resp{trailers = T}) -> T.

-spec with_status(100..599, resp()) -> resp().
with_status(Status, Resp) -> Resp#livery_resp{status = Status}.

-doc "Replace (or insert) a header. Names are matched case-insensitively.".
-spec with_header(header_name(), header_value(), resp()) -> resp().
with_header(Name, Value, #livery_resp{headers = Hs} = Resp) ->
    LName = lowercase(Name),
    Hs1 = lists:keystore(LName, 1, delete_all(LName, Hs), {LName, Value}),
    Resp#livery_resp{headers = Hs1}.

-doc "Append a header even when one with this name exists.".
-spec append_header(header_name(), header_value(), resp()) -> resp().
append_header(Name, Value, #livery_resp{headers = Hs} = Resp) ->
    Resp#livery_resp{headers = Hs ++ [{lowercase(Name), Value}]}.

-doc "Remove every header with this name.".
-spec delete_header(header_name(), resp()) -> resp().
delete_header(Name, #livery_resp{headers = Hs} = Resp) ->
    Resp#livery_resp{headers = delete_all(lowercase(Name), Hs)}.

-doc """
Attach trailers.

Pass a list of `{Name, Value}` pairs computed up front, or a fun
`fun() -> [{Name, Value}]` evaluated lazily after the body has
been emitted.
""".
-spec with_trailers(
    undefined
    | [{header_name(), header_value()}]
    | fun(() -> [{header_name(), header_value()}]),
    resp()
) -> resp().
with_trailers(Trailers, Resp) ->
    Resp#livery_resp{trailers = Trailers}.

-doc """
Replace the body variant, keeping status, headers, and trailers.

Used by middleware (e.g. `livery_compress`) that rewrites the body
after the handler has produced the response.
""".
-spec with_body(body(), resp()) -> resp().
with_body(Body, Resp) ->
    Resp#livery_resp{body = Body}.

-doc """
Set the `ETag` header.

A value already shaped as a strong (`"..."`) or weak (`W/"..."`) tag is
used as-is; a bare token is wrapped as a strong ETag.
""".
-spec with_etag(binary(), resp()) -> resp().
with_etag(Tag, Resp) ->
    with_header(<<"etag">>, format_etag(Tag), Resp).

-doc """
Set the `Cache-Control` header.

Pass a verbatim binary, or a list of directives: the atoms `no_cache`,
`no_store`, `public`, `private`, `immutable`, `must_revalidate`,
`proxy_revalidate`, `no_transform`, or the tuples `{max_age, Secs}`,
`{s_maxage, Secs}`, `{stale_while_revalidate, Secs}`,
`{stale_if_error, Secs}`.
""".
-spec with_cache_control(binary() | [cache_directive()], resp()) -> resp().
with_cache_control(Value, Resp) ->
    with_header(<<"cache-control">>, format_cache_control(Value), Resp).

%%====================================================================
%% Convenience builders
%%====================================================================

-doc "`text/plain; charset=utf-8` response.".
-spec text(100..599, iodata()) -> resp().
text(Status, Body) -> text(Status, [], Body).

-doc "`text/2` with extra headers.".
-spec text(100..599, [{header_name(), header_value()}], iodata()) -> resp().
text(Status, ExtraHeaders, Body) ->
    new(
        Status,
        with_default(
            <<"content-type">>,
            <<"text/plain; charset=utf-8">>,
            ExtraHeaders
        ),
        {full, Body}
    ).

-doc "`text/html; charset=utf-8` response.".
-spec html(100..599, iodata()) -> resp().
html(Status, Body) -> html(Status, [], Body).

-doc "`html/2` with extra headers.".
-spec html(100..599, [{header_name(), header_value()}], iodata()) -> resp().
html(Status, ExtraHeaders, Body) ->
    new(
        Status,
        with_default(
            <<"content-type">>,
            <<"text/html; charset=utf-8">>,
            ExtraHeaders
        ),
        {full, Body}
    ).

-doc """
Wrap pre-encoded JSON bytes as a response.

Livery does not bundle a JSON codec. Pass already-encoded iodata.
Higher-level helpers plugging in `thoas` or `jsx` can sit on top
of this builder.
""".
-spec json(100..599, iodata()) -> resp().
json(Status, Body) -> json(Status, [], Body).

-doc "`json/2` with extra headers.".
-spec json(100..599, [{header_name(), header_value()}], iodata()) -> resp().
json(Status, ExtraHeaders, Body) ->
    new(
        Status,
        with_default(
            <<"content-type">>,
            <<"application/json">>,
            ExtraHeaders
        ),
        {full, Body}
    ).

-doc "Headers-only response.".
-spec empty(100..599) -> resp().
empty(Status) ->
    new(Status, [], empty).

-doc """
Streaming chunked response.

The producer is called with a `SendFun` and drives body chunks
until it returns.
""".
-spec stream(
    100..599,
    [{header_name(), header_value()}],
    fun((term()) -> ok | {error, term()})
) -> resp().
stream(Status, Headers, Producer) when is_function(Producer, 1) ->
    new(Status, Headers, {chunked, Producer}).

-doc """
Deferred response: choose the status, headers, and body shape at the
first byte rather than at construction.

`stream/3`, `sse/3`, and `ndjson/3` fix the status and headers when the
response is built, so the status is on the wire before the producer runs.
That blocks the "admit, then stream; if admission fails before the first
byte, reply with an error status" pattern: a saturated request can only
emit `200 OK` followed by an in-band error frame, never `429` + a JSON
envelope.

`Resolver` is invoked once, in the handler's process, before any header
is written. It returns one of:

- `{stream, Status, Headers, Producer}`  -- like `stream/3`
- `{sse, Status, Headers, Producer}`     -- like `sse/3`
- `{ndjson, Status, Headers, Producer}`  -- like `ndjson/3`
- `{full, Status, Headers, Body}`        -- a one-shot full response

```erlang
livery_resp:stream_deferred(fun() ->
    case admit() of
        ok            -> {sse, 200, [], fun(Emit) -> drive(Emit) end};
        pool_exhausted -> {full, 429, [{<<"content-type">>, <<"application/json">>}],
                           <<"{\\"error\\":\\"busy\\"}">>}
    end
end).
```

Headers added by middleware that wraps the handler (request id, security
headers, CORS) are kept; the decision's own headers win on a name
conflict. An invalid decision crashes before any byte is sent, so it
surfaces as a clean 500.
""".
-spec stream_deferred(fun(() -> deferred_decision())) -> resp().
stream_deferred(Resolver) when is_function(Resolver, 0) ->
    new(200, [], {deferred, Resolver}).

-doc "Resolve a deferred decision into a concrete response.".
-spec resolve_deferred(deferred_decision()) -> resp().
resolve_deferred(Decision) ->
    resolve_deferred([], Decision).

-doc """
`resolve_deferred/1` merging `OuterHeaders` (e.g. headers added by
middleware to the deferred wrapper) under the decision's headers. The
decision wins on a name conflict.
""".
-spec resolve_deferred([{header_name(), header_value()}], deferred_decision()) ->
    resp().
resolve_deferred(OuterHeaders, Decision) ->
    Resolved = from_decision(Decision),
    Merged = merge_under(OuterHeaders, headers(Resolved)),
    Resolved#livery_resp{headers = Merged}.

-spec from_decision(deferred_decision()) -> resp().
from_decision({stream, Status, Headers, Producer}) ->
    stream(Status, Headers, Producer);
from_decision({sse, Status, Headers, Producer}) ->
    sse(Status, Headers, Producer);
from_decision({ndjson, Status, Headers, Producer}) ->
    ndjson(Status, Headers, Producer);
from_decision({full, Status, Headers, Body}) ->
    new(Status, Headers, {full, Body}).

%% Higher (the decision) wins on a name conflict; Lower entries survive
%% only when their lowercased name is absent from Higher.
-spec merge_under(
    [{header_name(), header_value()}],
    [{header_name(), header_value()}]
) -> [{header_name(), header_value()}].
merge_under(Lower, Higher) ->
    Names = [string:lowercase(K) || {K, _} <- Higher],
    Extra = [
        KV
     || {K, _} = KV <- Lower,
        not lists:member(string:lowercase(K), Names)
    ],
    Higher ++ Extra.

-doc "Server-Sent Events response.".
-spec sse(100..599, fun((term()) -> ok | {error, term()})) -> resp().
sse(Status, Producer) -> sse(Status, [], Producer).

-doc "`sse/2` with extra headers.".
-spec sse(
    100..599,
    [{header_name(), header_value()}],
    fun((term()) -> ok | {error, term()})
) -> resp().
sse(Status, ExtraHeaders, Producer) when is_function(Producer, 1) ->
    Hs0 = with_default(<<"content-type">>, <<"text/event-stream">>, ExtraHeaders),
    Hs1 = with_default(<<"cache-control">>, <<"no-cache">>, Hs0),
    new(Status, Hs1, {sse, Producer}).

-doc """
Newline-delimited JSON streaming response.

The producer is called with an `Emit` callback that takes any
JSON-encodable Erlang term. Each `Emit(Term)` encodes the term
via the OTP `json` module, appends a literal `\\n`, and writes
one frame. Content-Type defaults to `application/x-ndjson`.

```erlang
livery_resp:ndjson(200, fun(Emit) ->
    [Emit(#{n => N}) || N <- lists:seq(1, 5)],
    ok
end).
```

For pre-encoded bytes, use `stream/3` directly.
""".
-spec ndjson(100..599, fun((term()) -> ok | {error, term()})) -> resp().
ndjson(Status, Producer) -> ndjson(Status, [], Producer).

-doc "`ndjson/2` with extra headers.".
-spec ndjson(
    100..599,
    [{header_name(), header_value()}],
    fun((term()) -> ok | {error, term()})
) -> resp().
ndjson(Status, ExtraHeaders, Producer) when is_function(Producer, 1) ->
    Hs = with_default(
        <<"content-type">>,
        <<"application/x-ndjson">>,
        ExtraHeaders
    ),
    Wrapped = fun(Emit) ->
        Encode = fun(Term) ->
            Emit([json:encode(Term), <<"\n">>])
        end,
        Producer(Encode)
    end,
    new(Status, Hs, {chunked, Wrapped}).

-doc """
Send a file from the filesystem.

Range is `undefined` for the whole file, or `{Offset, Length}`
where `Length` may be `eof`.
""".
-spec file(100..599, file:name_all()) -> resp().
file(Status, Path) -> file(Status, Path, undefined).

-doc "`file/2` with an explicit byte range.".
-spec file(
    100..599,
    file:name_all(),
    undefined | {non_neg_integer(), non_neg_integer() | eof}
) -> resp().
file(Status, Path, Range) ->
    new(Status, [], {file, Path, Range}).

-doc "Redirect response, setting the `Location` header.".
-spec redirect(301 | 302 | 303 | 307 | 308, iodata()) -> resp().
redirect(Status, Location) -> redirect(Status, Location, []).

-doc "`redirect/2` with extra headers.".
-spec redirect(
    301 | 302 | 303 | 307 | 308,
    iodata(),
    [{header_name(), header_value()}]
) -> resp().
redirect(Status, Location, ExtraHeaders) ->
    new(
        Status,
        [{<<"location">>, iolist_to_binary(Location)} | ExtraHeaders],
        empty
    ).

-doc "Protocol upgrade response (WebSocket / WebTransport).".
-spec upgrade(ws | wt, term()) -> resp().
upgrade(Kind, State) when Kind =:= ws; Kind =:= wt ->
    #livery_resp{
        status = 101,
        headers = [],
        body = {upgrade, Kind, State}
    }.

%%====================================================================
%% Helpers
%%====================================================================

-spec with_default(
    header_name(),
    header_value(),
    [{header_name(), header_value()}]
) ->
    [{header_name(), header_value()}].
with_default(Name, Default, Headers) ->
    LName = lowercase(Name),
    Normalized = normalize_headers(Headers),
    case lists:keyfind(LName, 1, Normalized) of
        {_, _} -> Normalized;
        false -> [{LName, Default} | Normalized]
    end.

-spec normalize_headers([{header_name(), header_value()}]) ->
    [{header_name(), header_value()}].
normalize_headers(Hs) ->
    [{lowercase(N), V} || {N, V} <- Hs].

-spec lowercase(binary()) -> binary().
lowercase(Bin) when is_binary(Bin) ->
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

-spec format_etag(binary()) -> binary().
format_etag(<<"W/", _/binary>> = Weak) -> Weak;
format_etag(<<$", _/binary>> = Quoted) -> Quoted;
format_etag(Tag) -> <<$", Tag/binary, $">>.

-spec format_cache_control(binary() | [cache_directive()]) -> binary().
format_cache_control(Value) when is_binary(Value) ->
    Value;
format_cache_control(Directives) when is_list(Directives) ->
    iolist_to_binary(lists:join(<<", ">>, [cc_directive(D) || D <- Directives])).

-spec cc_directive(cache_directive()) -> binary().
cc_directive(no_cache) ->
    <<"no-cache">>;
cc_directive(no_store) ->
    <<"no-store">>;
cc_directive(public) ->
    <<"public">>;
cc_directive(private) ->
    <<"private">>;
cc_directive(immutable) ->
    <<"immutable">>;
cc_directive(must_revalidate) ->
    <<"must-revalidate">>;
cc_directive(proxy_revalidate) ->
    <<"proxy-revalidate">>;
cc_directive(no_transform) ->
    <<"no-transform">>;
cc_directive({max_age, Secs}) ->
    <<"max-age=", (integer_to_binary(Secs))/binary>>;
cc_directive({s_maxage, Secs}) ->
    <<"s-maxage=", (integer_to_binary(Secs))/binary>>;
cc_directive({stale_while_revalidate, Secs}) ->
    <<"stale-while-revalidate=", (integer_to_binary(Secs))/binary>>;
cc_directive({stale_if_error, Secs}) ->
    <<"stale-if-error=", (integer_to_binary(Secs))/binary>>.
