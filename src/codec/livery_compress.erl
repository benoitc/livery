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

## Negotiation

A coding is acceptable iff its `Accept-Encoding` q-value is `> 0` (by
exact name or `*`; `q=0` rejects). Among acceptable codings the SERVER
preference order wins; client q-weights are only an accept/reject
filter. With no acceptable coding the response is sent uncompressed
(identity); `identity;q=0` is deliberately treated as identity, not a
`406`.

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
                none -> Resp1;
                {ok, Codec} -> apply_codec(Codec, Resp1)
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

-spec choose(binary(), [module()]) -> none | {ok, module()}.
choose(Accept, Codecs) ->
    select(Codecs, parse_accept_encoding(Accept)).

-spec select([module()], #{binary() => float()}) -> none | {ok, module()}.
select([], _Accepted) ->
    none;
select([Codec | Rest], Accepted) ->
    case acceptable(normalize(Codec:name()), Accepted) of
        true -> {ok, Codec};
        false -> select(Rest, Accepted)
    end.

-spec acceptable(binary(), #{binary() => float()}) -> boolean().
acceptable(Name, Accepted) ->
    case maps:find(Name, Accepted) of
        {ok, Q} -> Q > 0;
        error -> wildcard_q(Accepted) > 0
    end.

-spec wildcard_q(#{binary() => float()}) -> float().
wildcard_q(Accepted) ->
    maps:get(<<"*">>, Accepted, 0.0).

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
            {Coding, Q} = split_q(Trimmed),
            maps:put(normalize(Coding), Q, Acc)
    end.

-spec split_q(binary()) -> {binary(), float()}.
split_q(Entry) ->
    case binary:split(Entry, <<";">>) of
        [Coding] -> {Coding, 1.0};
        [Coding, Params] -> {Coding, parse_q(Params)}
    end.

-spec parse_q(binary()) -> float().
parse_q(Params) ->
    Lower = iolist_to_binary(string:lowercase(Params)),
    find_q(binary:split(Lower, <<";">>, [global])).

-spec find_q([binary()]) -> float().
find_q([]) ->
    1.0;
find_q([Token | Rest]) ->
    case iolist_to_binary(string:trim(Token)) of
        <<"q=", Value/binary>> -> to_q(Value);
        _Other -> find_q(Rest)
    end.

-spec to_q(binary()) -> float().
to_q(Value) ->
    Str = binary_to_list(iolist_to_binary(string:trim(Value))),
    case string:to_float(Str) of
        {Float, _Rest} when is_float(Float) ->
            Float;
        {error, _} ->
            case string:to_integer(Str) of
                {Int, _} when is_integer(Int) -> float(Int);
                {error, _} -> 0.0
            end
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
