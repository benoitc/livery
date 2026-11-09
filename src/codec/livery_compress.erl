-module(livery_compress).
-moduledoc """
Response-compression middleware.

Negotiates the client's `Accept-Encoding` against the registered
`livery_codec` codecs and compresses eligible responses, setting
`Content-Encoding` and a cache-correct `Vary: Accept-Encoding`. gzip and
deflate are built in (OTP `zlib`); brotli/zstd become available when
their apps register a codec. Configure as a stack entry
`{livery_compress, Config}` where every key is optional:

- `codecs` — list of codec modules in server-preference order
  (default `livery_codec:registered()`); restricts/overrides the set.
- `min_size` — minimum `{full, _}` body size to compress (default 1024).
- `types` — compressible `Content-Type` prefixes (default text and the
  common structured types).

## Negotiation (RFC 9110 section 12.5.3)

Each coding gets the q-value of its own `Accept-Encoding` entry, or of
`*`, or 0. The codec with the highest q above 0 wins; the `codecs` order
only breaks ties. Unencoded content (`identity`) is acceptable unless
`identity;q=0`, or `*;q=0` with no `identity` entry, refuses it. When
the client names it (or `*`), it wins if its q is higher than every
codec's; when it does not, it is used only if no codec is acceptable. When no codec is
acceptable and identity is refused, the response is `406 Not
Acceptable`. A malformed q-value makes Livery ignore that entry. An
absent or empty `Accept-Encoding` gets unencoded content.

## Scope

Only `{full, _}` (>= `min_size`) and `{chunked, _}` bodies with a
compressible `Content-Type` and no existing `Content-Encoding` are
eligible. SSE, file, empty, and upgrade bodies pass through unchanged.
""".
-behaviour(livery_middleware).

-export([call/3]).

-doc "Compress the downstream response when the client accepts a codec.".
-spec call(livery_req:req(), livery_middleware:next(), map() | undefined) ->
    livery_resp:resp().
call(Req, Next, State) ->
    Cfg = config(State),
    Resp = Next(Req),
    case eligible(Resp, Cfg) of
        false ->
            Resp;
        true ->
            Resp1 = append_vary(<<"Accept-Encoding">>, Resp),
            Accept = livery_req:header(<<"accept-encoding">>, Req, <<>>),
            case choose(Accept, maps:get(codecs, Cfg)) of
                identity ->
                    Resp1;
                {ok, Codec} ->
                    apply_codec(Codec, Resp1);
                not_acceptable ->
                    append_vary(<<"Accept-Encoding">>, livery_resp:text(406, <<"not acceptable">>))
            end
    end.

%%====================================================================
%% Eligibility
%%====================================================================

-spec eligible(livery_resp:resp(), map()) -> boolean().
eligible(Resp, Cfg) ->
    not has_content_encoding(Resp) andalso
        body_eligible(livery_resp:body(Resp), Cfg) andalso
        type_compressible(Resp, Cfg).

-spec has_content_encoding(livery_resp:resp()) -> boolean().
has_content_encoding(Resp) ->
    lists:keymember(<<"content-encoding">>, 1, livery_resp:headers(Resp)).

-spec body_eligible(livery_resp:body(), map()) -> boolean().
body_eligible({full, Body}, Cfg) ->
    iolist_size(Body) >= maps:get(min_size, Cfg);
body_eligible({chunked, _Producer}, _Cfg) ->
    true;
body_eligible(_Other, _Cfg) ->
    false.

-spec type_compressible(livery_resp:resp(), map()) -> boolean().
type_compressible(Resp, Cfg) ->
    case content_type(Resp) of
        undefined ->
            false;
        Value ->
            Norm = normalize_ct(Value),
            lists:any(
                fun(Prefix) -> is_prefix(Prefix, Norm) end,
                maps:get(types, Cfg)
            )
    end.

-spec content_type(livery_resp:resp()) -> binary() | undefined.
content_type(Resp) ->
    case lists:keyfind(<<"content-type">>, 1, livery_resp:headers(Resp)) of
        {_, Value} -> Value;
        false -> undefined
    end.

-spec normalize_ct(binary()) -> binary().
normalize_ct(Value) ->
    Lower = iolist_to_binary(string:lowercase(Value)),
    [Main | _] = binary:split(Lower, <<";">>),
    iolist_to_binary(string:trim(Main)).

-spec is_prefix(binary(), binary()) -> boolean().
is_prefix(Prefix, Bin) when byte_size(Bin) >= byte_size(Prefix) ->
    PrefixSize = byte_size(Prefix),
    <<Head:PrefixSize/binary, _/binary>> = Bin,
    Head =:= Prefix;
is_prefix(_Prefix, _Bin) ->
    false.

%%====================================================================
%% Negotiation
%%====================================================================

-spec choose(binary(), [module()]) -> {ok, module()} | identity | not_acceptable.
choose(Accept, Codecs) ->
    Accepted = parse_accept_encoding(Accept),
    Ranked = [
        {Q, -I, Codec}
     || {I, Codec} <- lists:enumerate(Codecs),
        Q <- [q(normalize(Codec:name()), Accepted, 0.0)],
        Q > 0
    ],
    case {lists:reverse(lists:sort(Ranked)), identity_q(Accepted)} of
        {[{_, _, Codec} | _], fallback} -> {ok, Codec};
        {[{Q, _, Codec} | _], IdQ} when Q >= IdQ -> {ok, Codec};
        {_, fallback} -> identity;
        {_, IdQ} when IdQ > 0 -> identity;
        _ -> not_acceptable
    end.

%% A coding's own entry, else `*', else `Default'.
q(Name, Accepted, Default) ->
    case maps:find(Name, Accepted) of
        {ok, Q} -> Q;
        error -> maps:get(<<"*">>, Accepted, Default)
    end.

%% Rule 2: unencoded is acceptable unless `identity' or `*' says q=0. Not
%% named at all, it is only the fallback when no coding is acceptable;
%% named, its q competes with the codings'.
identity_q(Accepted) ->
    case q(<<"identity">>, Accepted, fallback) of
        fallback -> fallback;
        Q -> Q
    end.

-spec parse_accept_encoding(binary()) -> #{binary() => float()}.
parse_accept_encoding(Bin) ->
    lists:foldl(
        fun parse_entry/2, #{}, binary:split(Bin, <<",">>, [global])
    ).

-spec parse_entry(binary(), #{binary() => float()}) -> #{binary() => float()}.
parse_entry(Part, Acc) ->
    case iolist_to_binary(string:trim(Part)) of
        <<>> ->
            Acc;
        Trimmed ->
            case split_q(Trimmed) of
                {Coding, Q} -> maps:put(normalize(Coding), Q, Acc);
                error -> Acc
            end
    end.

-spec split_q(binary()) -> {binary(), float()} | error.
split_q(Entry) ->
    case binary:split(Entry, <<";">>) of
        [Coding] -> {Coding, 1.0};
        [Coding, Params] -> with_q(Coding, find_q(binary:split(Params, <<";">>, [global])))
    end.

with_q(Coding, {ok, Q}) -> {Coding, Q};
with_q(_Coding, error) -> error.

find_q([]) ->
    {ok, 1.0};
find_q([Token | Rest]) ->
    case string:lowercase(iolist_to_binary(string:trim(Token))) of
        <<"q=", Value/binary>> -> qvalue(Value);
        _Other -> find_q(Rest)
    end.

%% RFC 9110 12.4.2: qvalue = ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] )
qvalue(<<"1">>) -> {ok, 1.0};
qvalue(<<"1.", Zeros/binary>>) when byte_size(Zeros) =< 3 -> all_zeros(Zeros);
qvalue(<<"0">>) -> {ok, 0.0};
qvalue(<<"0.", Digits/binary>>) when byte_size(Digits) =< 3 -> fraction(Digits);
qvalue(_) -> error.

all_zeros(Zeros) ->
    case [C || <<C>> <= Zeros, C =/= $0] of
        [] -> {ok, 1.0};
        _ -> error
    end.

fraction(<<>>) ->
    {ok, 0.0};
fraction(Digits) ->
    case [C || <<C>> <= Digits, C < $0 orelse C > $9] of
        [] -> {ok, binary_to_integer(Digits) / math:pow(10, byte_size(Digits))};
        _ -> error
    end.

%%====================================================================
%% Apply
%%====================================================================

-spec apply_codec(module(), livery_resp:resp()) -> livery_resp:resp().
apply_codec(Codec, Resp) ->
    case livery_resp:body(Resp) of
        {full, Body} -> apply_full(Codec, Body, Resp);
        {chunked, Producer} -> apply_chunked(Codec, Producer, Resp)
    end.

-spec apply_full(module(), iodata(), livery_resp:resp()) -> livery_resp:resp().
apply_full(Codec, Body, Resp) ->
    Comp = iolist_to_binary(Codec:compress(Body)),
    R1 = livery_resp:with_body({full, Comp}, Resp),
    R2 = livery_resp:with_header(<<"content-encoding">>, Codec:name(), R1),
    case livery_resp:trailers(Resp) of
        undefined ->
            livery_resp:with_header(
                <<"content-length">>, integer_to_binary(byte_size(Comp)), R2
            );
        _Trailers ->
            livery_resp:delete_header(<<"content-length">>, R2)
    end.

-spec apply_chunked(
    module(), fun((term()) -> ok | {error, term()}), livery_resp:resp()
) -> livery_resp:resp().
apply_chunked(Codec, Producer, Resp) ->
    Wrapped = fun(Emit) -> stream(Codec, Producer, Emit) end,
    R1 = livery_resp:with_body({chunked, Wrapped}, Resp),
    R2 = livery_resp:with_header(<<"content-encoding">>, Codec:name(), R1),
    livery_resp:delete_header(<<"content-length">>, R2).

-spec stream(
    module(),
    fun((term()) -> ok | {error, term()}),
    fun((term()) -> ok | {error, term()})
) -> ok | {error, term()}.
stream(Codec, Producer, Emit) ->
    Ctx = Codec:stream_init(),
    EmitC = fun(Chunk) -> emit_compressed(Codec:stream_update(Ctx, Chunk), Emit) end,
    try Producer(EmitC) of
        {error, _} = Err -> Err;
        _Ok -> emit_compressed(Codec:stream_finish(Ctx), Emit)
    after
        Codec:stream_close(Ctx)
    end.

-spec emit_compressed(iodata(), fun((term()) -> ok | {error, term()})) ->
    ok | {error, term()}.
emit_compressed(Out, Emit) ->
    case iolist_size(Out) of
        0 -> ok;
        _ -> Emit(Out)
    end.

%%====================================================================
%% Vary
%%====================================================================

-spec append_vary(binary(), livery_resp:resp()) -> livery_resp:resp().
append_vary(Token, Resp) ->
    case vary_present(Token, Resp) of
        true -> Resp;
        false -> livery_resp:append_header(<<"vary">>, Token, Resp)
    end.

-spec vary_present(binary(), livery_resp:resp()) -> boolean().
vary_present(Token, Resp) ->
    LToken = normalize(Token),
    Existing = [V || {<<"vary">>, V} <- livery_resp:headers(Resp)],
    lists:any(
        fun(Value) -> lists:member(LToken, split_tokens(Value)) end, Existing
    ).

-spec split_tokens(binary()) -> [binary()].
split_tokens(Value) ->
    [normalize(P) || P <- binary:split(Value, <<",">>, [global])].

%%====================================================================
%% Config and helpers
%%====================================================================

-spec config(map() | undefined) -> map().
config(undefined) ->
    config(#{});
config(State) when is_map(State) ->
    #{
        codecs => maps:get(codecs, State, livery_codec:registered()),
        min_size => maps:get(min_size, State, 1024),
        types => maps:get(types, State, default_types())
    }.

-spec default_types() -> [binary()].
default_types() ->
    [
        <<"text/">>,
        <<"application/json">>,
        <<"application/javascript">>,
        <<"application/xml">>,
        <<"application/xhtml+xml">>,
        <<"image/svg+xml">>,
        <<"application/wasm">>,
        <<"application/x-ndjson">>
    ].

-spec normalize(binary()) -> binary().
normalize(Bin) ->
    iolist_to_binary(string:trim(string:lowercase(Bin))).
