-module(livery_etag).
-moduledoc """
ETag / conditional-GET middleware.

For cacheable `GET`/`HEAD` responses it ensures an `ETag` header and
answers `304 Not Modified` when the request's `If-None-Match` matches,
skipping the body transfer.

```erlang
Stack = [{livery_etag, #{}} | Rest].
```

By default a strong ETag is computed automatically from a `{full, _}`
body that has no ETag; a handler may instead set its own (via
`livery_resp:with_etag/2`), which is respected on ANY body variant.
Config keys (all optional): `auto` (default `true`), `weak` (default
`false`, auto ETags are strong), `statuses` (cacheable statuses, default
`[200]`).

Placement: put `livery_etag` OUTSIDE `livery_compress` (earlier in the
stack list) so the ETag covers the bytes actually sent; otherwise the
ETag is of the uncompressed body and you rely on `Vary: Accept-Encoding`
(which `livery_compress` already sets).
""".
-behaviour(livery_middleware).

-export([call/3, if_none_match/2]).

-define(STRIPPED, [
    <<"content-length">>,
    <<"content-type">>,
    <<"content-encoding">>,
    <<"content-range">>
]).

-doc "Add an ETag and answer 304 on a matching conditional GET.".
-spec call(livery_req:req(), livery_middleware:next(), map() | undefined) ->
    livery_resp:resp().
call(Req, Next, State) ->
    Cfg = config(State),
    Resp = Next(Req),
    case eligible(Req, Resp, Cfg) of
        false -> Resp;
        true -> conditional(Req, ensure_etag(Resp, Cfg))
    end.

%%====================================================================
%% Eligibility
%%====================================================================

-spec config(map() | undefined) -> map().
config(undefined) ->
    config(#{});
config(State) when is_map(State) ->
    #{
        auto => maps:get(auto, State, true),
        weak => maps:get(weak, State, false),
        statuses => maps:get(statuses, State, [200])
    }.

-spec eligible(livery_req:req(), livery_resp:resp(), map()) -> boolean().
eligible(Req, Resp, #{statuses := Statuses}) ->
    conditional_method(livery_req:method(Req)) andalso
        lists:member(livery_resp:status(Resp), Statuses).

-spec conditional_method(binary()) -> boolean().
conditional_method(<<"GET">>) -> true;
conditional_method(<<"HEAD">>) -> true;
conditional_method(_Other) -> false.

%%====================================================================
%% ETag
%%====================================================================

-spec ensure_etag(livery_resp:resp(), map()) -> livery_resp:resp().
ensure_etag(Resp, #{auto := Auto, weak := Weak}) ->
    case {has_etag(Resp), Auto} of
        {true, _} -> Resp;
        {false, true} -> auto_etag(Resp, Weak);
        {false, false} -> Resp
    end.

-spec has_etag(livery_resp:resp()) -> boolean().
has_etag(Resp) ->
    lists:keymember(<<"etag">>, 1, livery_resp:headers(Resp)).

-spec auto_etag(livery_resp:resp(), boolean()) -> livery_resp:resp().
auto_etag(Resp, Weak) ->
    case livery_resp:body(Resp) of
        {full, Body} ->
            livery_resp:with_header(<<"etag">>, compute_etag(Body, Weak), Resp);
        _Other ->
            Resp
    end.

-spec compute_etag(iodata(), boolean()) -> binary().
compute_etag(Body, Weak) ->
    Hash = base64:encode(binary:part(crypto:hash(sha256, Body), 0, 16)),
    case Weak of
        true -> <<"W/\"", Hash/binary, "\"">>;
        false -> <<$", Hash/binary, $">>
    end.

%%====================================================================
%% Conditional GET
%%====================================================================

-spec conditional(livery_req:req(), livery_resp:resp()) -> livery_resp:resp().
conditional(Req, Resp) ->
    case etag_value(Resp) of
        undefined ->
            Resp;
        ETag ->
            case if_none_match(Req, ETag) of
                true -> to_304(Resp);
                false -> Resp
            end
    end.

-spec etag_value(livery_resp:resp()) -> binary() | undefined.
etag_value(Resp) ->
    case lists:keyfind(<<"etag">>, 1, livery_resp:headers(Resp)) of
        {_, Value} -> Value;
        false -> undefined
    end.

-doc """
True if the request's `If-None-Match` matches `ETag`.

Honors `*` and uses RFC 9110 weak comparison. Exposed so other handlers
(e.g. `livery_static`) share one conditional-request implementation.
""".
-spec if_none_match(livery_req:req(), binary()) -> boolean().
if_none_match(Req, ETag) ->
    Tags = if_none_match_tags(Req),
    lists:member(<<"*">>, Tags) orelse
        lists:any(fun(Tag) -> weak_equal(Tag, ETag) end, Tags).

%% Collect every If-None-Match instance and comma-split each.
-spec if_none_match_tags(livery_req:req()) -> [binary()].
if_none_match_tags(Req) ->
    Values = livery_req:headers_all(<<"if-none-match">>, Req),
    lists:flatmap(fun split_tags/1, Values).

-spec split_tags(binary()) -> [binary()].
split_tags(Value) ->
    Parts = [trim(P) || P <- binary:split(Value, <<",">>, [global])],
    [P || P <- Parts, P =/= <<>>].

%% Weak comparison (RFC 9110): ignore a leading `W/` on either side.
-spec weak_equal(binary(), binary()) -> boolean().
weak_equal(A, B) ->
    strip_weak(A) =:= strip_weak(B).

-spec strip_weak(binary()) -> binary().
strip_weak(<<"W/", Rest/binary>>) -> Rest;
strip_weak(Tag) -> Tag.

-spec to_304(livery_resp:resp()) -> livery_resp:resp().
to_304(Resp) ->
    Kept = [
        Header
     || {Name, _} = Header <- livery_resp:headers(Resp),
        not lists:member(Name, ?STRIPPED)
    ],
    livery_resp:new(304, Kept, empty).

-spec trim(binary()) -> binary().
trim(Bin) ->
    iolist_to_binary(string:trim(Bin)).
