-module(livery_static).
-moduledoc """
Static-directory file handler.

Returns a handler that serves files from a root directory, inferring
`Content-Type` from the extension, emitting a weak ETag for conditional
GET, honoring `Range`, and confining every path under the root so a
request can never traverse out of it.

Mount it on a router wildcard route and read the captured sub-path:

```erlang
Router = livery_router:add(
    '_', <<"/assets/*path">>, livery_static:handler("priv/assets"), #{}, Router0
).
```

Without a router binding it falls back to stripping a configured
`prefix` from the request path. Options (all optional): `binding`
(default `<<"path">>`), `prefix`, `index` (default `<<"index.html">>`,
or `false`), `cache_control` (binary | directive list | `undefined`),
`etag` (default `true`), `range` (default `true`).

Security: the sub-path is percent-decoded and then confined - any `..`
segment, control byte, or escape is rejected - and only regular files
are served (directories and symlinks yield `404`).
""".

-include_lib("kernel/include/file.hrl").

-export([handler/1, handler/2]).

-type opts() :: #{
    binding => binary(),
    prefix => binary(),
    index => binary() | false,
    cache_control => binary() | [livery_resp:cache_directive()] | undefined,
    etag => boolean(),
    range => boolean()
}.

-export_type([opts/0]).

-doc "Static handler serving regular files under `Root`.".
-spec handler(file:name_all()) -> livery_middleware:handler().
handler(Root) ->
    handler(Root, #{}).

-doc "`handler/1` with options.".
-spec handler(file:name_all(), opts()) -> livery_middleware:handler().
handler(Root, Opts) ->
    NormRoot = normalize_root(Root),
    Cfg = config(Opts),
    fun(Req) -> serve(NormRoot, Cfg, Req) end.

%%====================================================================
%% Request handling
%%====================================================================

-spec serve(string(), map(), livery_req:req()) -> livery_resp:resp().
serve(Root, Cfg, Req) ->
    case livery_req:method(Req) of
        <<"GET">> -> locate(Root, Cfg, Req, <<"GET">>);
        <<"HEAD">> -> locate(Root, Cfg, Req, <<"HEAD">>);
        _Other -> method_not_allowed()
    end.

-spec locate(string(), map(), livery_req:req(), binary()) -> livery_resp:resp().
locate(Root, Cfg, Req, Method) ->
    case resolve(Root, sub_path(Req, Cfg), maps:get(index, Cfg)) of
        {ok, Path, Size, Mtime} ->
            serve_file(Req, Method, Path, Size, Mtime, Cfg);
        error ->
            not_found()
    end.

-spec serve_file(
    livery_req:req(), binary(), string(), non_neg_integer(), integer(), map()
) -> livery_resp:resp().
serve_file(Req, Method, Path, Size, Mtime, Cfg) ->
    ETag = etag(Size, Mtime),
    case maps:get(etag, Cfg) andalso livery_etag:if_none_match(Req, ETag) of
        true ->
            decorate(livery_resp:new(304, [], empty), ETag, Cfg);
        false ->
            body_response(Req, Method, Path, Size, ETag, Cfg)
    end.

-spec body_response(
    livery_req:req(), binary(), string(), non_neg_integer(), binary(), map()
) -> livery_resp:resp().
body_response(_Req, <<"HEAD">>, Path, Size, ETag, Cfg) ->
    Resp = livery_resp:new(
        200,
        [
            {<<"content-type">>, mime_type(Path)},
            {<<"content-length">>, integer_to_binary(Size)}
        ],
        empty
    ),
    decorate(Resp, ETag, Cfg);
body_response(Req, <<"GET">>, Path, Size, ETag, Cfg) ->
    Base =
        case maps:get(range, Cfg) andalso parse_range(Req, Size) of
            {Offset, Length} -> livery_resp:file(206, Path, {Offset, Length});
            _NoRange -> livery_resp:file(200, Path)
        end,
    Resp = livery_resp:with_header(<<"content-type">>, mime_type(Path), Base),
    decorate(Resp, ETag, Cfg).

-spec decorate(livery_resp:resp(), binary(), map()) -> livery_resp:resp().
decorate(Resp, ETag, #{etag := EtagOn, cache_control := CacheControl}) ->
    R1 =
        case EtagOn of
            true -> livery_resp:with_header(<<"etag">>, ETag, Resp);
            false -> Resp
        end,
    case CacheControl of
        undefined -> R1;
        _ -> livery_resp:with_cache_control(CacheControl, R1)
    end.

-spec method_not_allowed() -> livery_resp:resp().
method_not_allowed() ->
    livery_resp:with_header(
        <<"allow">>, <<"GET, HEAD">>, livery_resp:text(405, <<"method not allowed">>)
    ).

-spec not_found() -> livery_resp:resp().
not_found() ->
    livery_resp:text(404, <<"not found">>).

%%====================================================================
%% Path resolution + confinement
%%====================================================================

-spec sub_path(livery_req:req(), map()) -> binary().
sub_path(Req, #{binding := Binding, prefix := Prefix}) ->
    case livery_req:binding(Binding, Req) of
        undefined -> strip_prefix(livery_req:path(Req), Prefix);
        Sub -> Sub
    end.

-spec strip_prefix(binary(), binary() | undefined) -> binary().
strip_prefix(Path, undefined) ->
    strip_leading_slash(Path);
strip_prefix(Path, Prefix) ->
    Size = byte_size(Prefix),
    case Path of
        <<Prefix:Size/binary, Rest/binary>> -> Rest;
        _Other -> strip_leading_slash(Path)
    end.

-spec strip_leading_slash(binary()) -> binary().
strip_leading_slash(<<"/", Rest/binary>>) -> Rest;
strip_leading_slash(Path) -> Path.

-spec resolve(string(), binary(), binary() | false) ->
    {ok, string(), non_neg_integer(), integer()} | error.
resolve(Root, Sub, Index) ->
    case confine(Root, Sub) of
        error -> error;
        {ok, Path} -> stat(Path, Index)
    end.

-spec stat(string(), binary() | false) ->
    {ok, string(), non_neg_integer(), integer()} | error.
stat(Path, Index) ->
    case file:read_link_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Mtime}} ->
            {ok, Path, Size, Mtime};
        {ok, #file_info{type = directory}} ->
            stat_index(Path, Index);
        _Other ->
            error
    end.

-spec stat_index(string(), binary() | false) ->
    {ok, string(), non_neg_integer(), integer()} | error.
stat_index(_Path, false) ->
    error;
stat_index(Path, Index) when is_binary(Index) ->
    stat(filename:join(Path, binary_to_list(Index)), false).

%% Percent-decode, then split and reject any unsafe segment.
-spec confine(string(), binary()) -> {ok, string()} | error.
confine(Root, Sub) ->
    case percent_decode(Sub) of
        error ->
            error;
        {ok, Decoded} ->
            case clean_segments(binary:split(Decoded, <<"/">>, [global]), []) of
                {ok, Segments} -> {ok, filename:join([Root | Segments])};
                error -> error
            end
    end.

-spec clean_segments([binary()], [string()]) -> {ok, [string()]} | error.
clean_segments([], Acc) ->
    {ok, lists:reverse(Acc)};
clean_segments([Segment | Rest], Acc) ->
    case Segment of
        <<>> ->
            clean_segments(Rest, Acc);
        <<".">> ->
            clean_segments(Rest, Acc);
        <<"..">> ->
            error;
        _ ->
            case has_bad_byte(Segment) of
                true -> error;
                false -> clean_segments(Rest, [binary_to_list(Segment) | Acc])
            end
    end.

-spec has_bad_byte(binary()) -> boolean().
has_bad_byte(<<>>) -> false;
has_bad_byte(<<C, _/binary>>) when C < 32; C =:= 127 -> true;
has_bad_byte(<<_, Rest/binary>>) -> has_bad_byte(Rest).

-spec percent_decode(binary()) -> {ok, binary()} | error.
percent_decode(Bin) ->
    percent_decode(Bin, <<>>).

-spec percent_decode(binary(), binary()) -> {ok, binary()} | error.
percent_decode(<<>>, Acc) ->
    {ok, Acc};
percent_decode(<<$%, H1, H2, Rest/binary>>, Acc) ->
    case {hex(H1), hex(H2)} of
        {{ok, A}, {ok, B}} -> percent_decode(Rest, <<Acc/binary, (A * 16 + B)>>);
        _Bad -> error
    end;
percent_decode(<<$%, _/binary>>, _Acc) ->
    error;
percent_decode(<<C, Rest/binary>>, Acc) ->
    percent_decode(Rest, <<Acc/binary, C>>).

-spec hex(byte()) -> {ok, 0..15} | error.
hex(C) when C >= $0, C =< $9 -> {ok, C - $0};
hex(C) when C >= $a, C =< $f -> {ok, C - $a + 10};
hex(C) when C >= $A, C =< $F -> {ok, C - $A + 10};
hex(_C) -> error.

%%====================================================================
%% ETag, MIME, Range
%%====================================================================

-spec etag(non_neg_integer(), integer()) -> binary().
etag(Size, Mtime) ->
    S = integer_to_binary(Size),
    M = integer_to_binary(Mtime),
    <<"W/\"", S/binary, "-", M/binary, "\"">>.

-spec mime_type(string()) -> binary().
mime_type(Path) ->
    Ext = string:lowercase(filename:extension(Path)),
    maps:get(iolist_to_binary(Ext), mime_map(), <<"application/octet-stream">>).

-spec mime_map() -> #{binary() => binary()}.
mime_map() ->
    #{
        <<".html">> => <<"text/html; charset=utf-8">>,
        <<".htm">> => <<"text/html; charset=utf-8">>,
        <<".css">> => <<"text/css; charset=utf-8">>,
        <<".js">> => <<"text/javascript; charset=utf-8">>,
        <<".mjs">> => <<"text/javascript; charset=utf-8">>,
        <<".json">> => <<"application/json">>,
        <<".xml">> => <<"application/xml">>,
        <<".txt">> => <<"text/plain; charset=utf-8">>,
        <<".md">> => <<"text/markdown; charset=utf-8">>,
        <<".csv">> => <<"text/csv; charset=utf-8">>,
        <<".svg">> => <<"image/svg+xml">>,
        <<".png">> => <<"image/png">>,
        <<".jpg">> => <<"image/jpeg">>,
        <<".jpeg">> => <<"image/jpeg">>,
        <<".gif">> => <<"image/gif">>,
        <<".webp">> => <<"image/webp">>,
        <<".avif">> => <<"image/avif">>,
        <<".ico">> => <<"image/x-icon">>,
        <<".woff">> => <<"font/woff">>,
        <<".woff2">> => <<"font/woff2">>,
        <<".ttf">> => <<"font/ttf">>,
        <<".otf">> => <<"font/otf">>,
        <<".wasm">> => <<"application/wasm">>,
        <<".pdf">> => <<"application/pdf">>,
        <<".zip">> => <<"application/zip">>,
        <<".gz">> => <<"application/gzip">>,
        <<".map">> => <<"application/json">>,
        <<".webmanifest">> => <<"application/manifest+json">>,
        <<".mp4">> => <<"video/mp4">>,
        <<".webm">> => <<"video/webm">>,
        <<".mp3">> => <<"audio/mpeg">>,
        <<".wav">> => <<"audio/wav">>
    }.

%% Parse a single `Range: bytes=A-B | A- | -N` into `{Offset, Length|eof}`;
%% `undefined` when absent, multi-range, or malformed (emit yields 416 on
%% an unsatisfiable but well-formed range).
-spec parse_range(livery_req:req(), non_neg_integer()) ->
    {non_neg_integer(), non_neg_integer() | eof} | undefined.
parse_range(Req, Size) ->
    case livery_req:header(<<"range">>, Req) of
        <<"bytes=", Spec/binary>> -> range_spec(Spec, Size);
        _Other -> undefined
    end.

-spec range_spec(binary(), non_neg_integer()) ->
    {non_neg_integer(), non_neg_integer() | eof} | undefined.
range_spec(Spec, Size) ->
    case binary:split(Spec, <<"-">>) of
        [<<>>, SuffixBin] -> suffix_range(SuffixBin, Size);
        [StartBin, <<>>] -> open_range(StartBin);
        [StartBin, EndBin] -> closed_range(StartBin, EndBin);
        _Other -> undefined
    end.

-spec suffix_range(binary(), non_neg_integer()) ->
    {non_neg_integer(), eof} | undefined.
suffix_range(SuffixBin, Size) ->
    case to_int(SuffixBin) of
        {ok, N} when N > 0 -> {max(0, Size - N), eof};
        _Other -> undefined
    end.

-spec open_range(binary()) -> {non_neg_integer(), eof} | undefined.
open_range(StartBin) ->
    case to_int(StartBin) of
        {ok, Start} -> {Start, eof};
        error -> undefined
    end.

-spec closed_range(binary(), binary()) ->
    {non_neg_integer(), non_neg_integer()} | undefined.
closed_range(StartBin, EndBin) ->
    case {to_int(StartBin), to_int(EndBin)} of
        {{ok, Start}, {ok, End}} when Start =< End -> {Start, End - Start + 1};
        _Other -> undefined
    end.

-spec to_int(binary()) -> {ok, non_neg_integer()} | error.
to_int(Bin) ->
    case string:to_integer(Bin) of
        {Int, <<>>} when is_integer(Int), Int >= 0 -> {ok, Int};
        _Other -> error
    end.

%%====================================================================
%% Config
%%====================================================================

-spec config(opts()) -> map().
config(Opts) ->
    #{
        binding => maps:get(binding, Opts, <<"path">>),
        prefix => maps:get(prefix, Opts, undefined),
        index => maps:get(index, Opts, <<"index.html">>),
        cache_control => maps:get(cache_control, Opts, undefined),
        etag => maps:get(etag, Opts, true),
        range => maps:get(range, Opts, true)
    }.

-spec normalize_root(file:name_all()) -> string().
normalize_root(Root) when is_binary(Root) -> binary_to_list(Root);
normalize_root(Root) -> Root.
