-module(livery_openapi_validate).
-moduledoc """
Request validation against a JSON-Schema subset, plus a middleware
that rejects malformed request bodies with `422`.

`validate/2` checks a decoded JSON term (maps with binary keys,
lists, binaries, numbers, booleans, `null`) against a schema map.

Supported keywords:

- core: `type` (single or a list of types), `enum`, `const`
- numbers: `minimum`, `maximum`, `exclusiveMinimum`,
  `exclusiveMaximum`, `multipleOf`
- strings: `minLength`, `maxLength`, `pattern`
- objects: `required`, `properties`, `additionalProperties`
  (`false` or a schema), `minProperties`, `maxProperties`
- arrays: `items`, `minItems`, `maxItems`, `uniqueItems`
- combinators: `allOf`, `anyOf`, `oneOf`

Schema keys may be atoms or binaries; property names inside
`properties` must be binaries (they are matched against decoded
JSON keys). It is a pragmatic subset, not a complete JSON Schema
implementation (`$ref`, `if`/`then`/`else`, `patternProperties`,
and `dependentSchemas` are not supported).

The `call/3` middleware reads `#{body_schema => Schema}` from its
state, decodes the request's JSON body, validates it, and on
failure short-circuits with a `422` whose body lists the errors.
On success it stores the decoded body under `meta(body, Decoded)`.
""".
-behaviour(livery_middleware).

-include("livery.hrl").

-export([validate/2, call/3]).

-export_type([schema/0, error/0]).

-type schema() :: map().
-type error() :: {binary(), binary()}.

%%====================================================================
%% Validation
%%====================================================================

-doc "Validate a decoded JSON term against a schema subset.".
-spec validate(term(), schema()) -> ok | {error, [error()]}.
validate(Value, Schema) ->
    case check(Value, Schema, <<"$">>, []) of
        []   -> ok;
        Errs -> {error, lists:reverse(Errs)}
    end.

check(Value, Schema, Path, Errs) ->
    case type_check(Value, Schema) of
        ok ->
            Errs1 = keywords(Value, Schema, Path, Errs),
            combinators(Value, Schema, Path, Errs1);
        {error, Msg} ->
            [{Path, Msg} | Errs]
    end.

type_check(Value, Schema) ->
    case sget(type, Schema) of
        undefined ->
            ok;
        Types when is_list(Types) ->
            case lists:any(fun(T) -> type_ok(T, Value) end, Types) of
                true  -> ok;
                false -> {error, type_error_list(Types)}
            end;
        Type ->
            case type_ok(Type, Value) of
                true  -> ok;
                false -> {error, type_error(Type)}
            end
    end.

keywords(Value, Schema, Path, Errs) ->
    Checks = [
        fun check_const/4,
        fun check_enum/4,
        fun check_bounds/4,
        fun check_multiple_of/4,
        fun check_length/4,
        fun check_pattern/4,
        fun check_required/4,
        fun check_properties/4,
        fun check_property_count/4,
        fun check_additional_properties/4,
        fun check_items/4,
        fun check_array_constraints/4
    ],
    lists:foldl(fun(Check, Acc) -> Check(Value, Schema, Path, Acc) end,
                Errs, Checks).

%%====================================================================
%% Combinators: allOf / anyOf / oneOf
%%====================================================================

combinators(Value, Schema, Path, Errs) ->
    Errs1 = check_all_of(Value, Schema, Path, Errs),
    Errs2 = check_any_of(Value, Schema, Path, Errs1),
    check_one_of(Value, Schema, Path, Errs2).

check_all_of(Value, Schema, Path, Errs) ->
    case sget(allOf, Schema) of
        Schemas when is_list(Schemas) ->
            lists:foldl(fun(S, Acc) -> check(Value, S, Path, Acc) end,
                        Errs, Schemas);
        _ ->
            Errs
    end.

check_any_of(Value, Schema, Path, Errs) ->
    case sget(anyOf, Schema) of
        Schemas when is_list(Schemas) ->
            case lists:any(fun(S) -> validate(Value, S) =:= ok end, Schemas) of
                true  -> Errs;
                false -> [{Path, <<"does not match any schema in anyOf">>} | Errs]
            end;
        _ ->
            Errs
    end.

check_one_of(Value, Schema, Path, Errs) ->
    case sget(oneOf, Schema) of
        Schemas when is_list(Schemas) ->
            Matches = length([S || S <- Schemas, validate(Value, S) =:= ok]),
            case Matches of
                1 -> Errs;
                _ -> [{Path, <<"must match exactly one schema in oneOf">>} | Errs]
            end;
        _ ->
            Errs
    end.

%%====================================================================
%% Keyword checks
%%====================================================================

check_const(Value, Schema, Path, Errs) ->
    case sget(const, Schema) of
        undefined -> Errs;
        Const when Value =:= Const -> Errs;
        _ -> [{Path, <<"does not equal const">>} | Errs]
    end.

check_enum(Value, Schema, Path, Errs) ->
    case sget(enum, Schema) of
        undefined -> Errs;
        Allowed ->
            case lists:member(Value, Allowed) of
                true  -> Errs;
                false -> [{Path, <<"not one of the allowed values">>} | Errs]
            end
    end.

check_bounds(Value, Schema, Path, Errs) when is_number(Value) ->
    E1 = bound(Value, sget(minimum, Schema),
               fun(V, M) -> V < M end, <<"below minimum">>, Path, Errs),
    E2 = bound(Value, sget(maximum, Schema),
               fun(V, M) -> V > M end, <<"above maximum">>, Path, E1),
    E3 = bound(Value, sget(exclusiveMinimum, Schema),
               fun(V, M) -> V =< M end,
               <<"not above exclusiveMinimum">>, Path, E2),
    bound(Value, sget(exclusiveMaximum, Schema),
          fun(V, M) -> V >= M end,
          <<"not below exclusiveMaximum">>, Path, E3);
check_bounds(_Value, _Schema, _Path, Errs) ->
    Errs.

bound(_Value, undefined, _Fail, _Msg, _Path, Errs) ->
    Errs;
bound(Value, Limit, Fail, Msg, Path, Errs) when is_number(Limit) ->
    case Fail(Value, Limit) of
        true  -> [{Path, Msg} | Errs];
        false -> Errs
    end;
bound(_Value, _Limit, _Fail, _Msg, _Path, Errs) ->
    Errs.

check_multiple_of(Value, Schema, Path, Errs) when is_number(Value) ->
    case sget(multipleOf, Schema) of
        M when is_number(M), M > 0 ->
            Ratio = Value / M,
            case Ratio == trunc(Ratio) of
                true  -> Errs;
                false -> [{Path, <<"not a multiple of">>} | Errs]
            end;
        _ ->
            Errs
    end;
check_multiple_of(_Value, _Schema, _Path, Errs) ->
    Errs.

check_pattern(Value, Schema, Path, Errs) when is_binary(Value) ->
    case sget(pattern, Schema) of
        Pattern when is_binary(Pattern) ->
            case re:run(Value, Pattern, [unicode]) of
                {match, _} -> Errs;
                nomatch    -> [{Path, <<"does not match pattern">>} | Errs];
                {error, _} -> Errs
            end;
        _ ->
            Errs
    end;
check_pattern(_Value, _Schema, _Path, Errs) ->
    Errs.

check_length(Value, Schema, Path, Errs) when is_binary(Value) ->
    Len = byte_size(Value),
    Errs1 = case sget(minLength, Schema) of
        undefined -> Errs;
        Min when Len < Min -> [{Path, <<"shorter than minLength">>} | Errs];
        _ -> Errs
    end,
    case sget(maxLength, Schema) of
        undefined -> Errs1;
        Max when Len > Max -> [{Path, <<"longer than maxLength">>} | Errs1];
        _ -> Errs1
    end;
check_length(_Value, _Schema, _Path, Errs) ->
    Errs.

check_required(Value, Schema, Path, Errs) when is_map(Value) ->
    case sget(required, Schema) of
        undefined -> Errs;
        Names ->
            lists:foldl(fun(Name, Acc) ->
                case maps:is_key(Name, Value) of
                    true  -> Acc;
                    false -> [{join(Path, Name),
                               <<"required property missing">>} | Acc]
                end
            end, Errs, Names)
    end;
check_required(_Value, _Schema, _Path, Errs) ->
    Errs.

check_properties(Value, Schema, Path, Errs) when is_map(Value) ->
    case sget(properties, Schema) of
        undefined -> Errs;
        Props ->
            maps:fold(fun(Name, PropSchema, Acc) ->
                case maps:find(Name, Value) of
                    {ok, V} -> check(V, PropSchema, join(Path, Name), Acc);
                    error   -> Acc
                end
            end, Errs, Props)
    end;
check_properties(_Value, _Schema, _Path, Errs) ->
    Errs.

check_items(Value, Schema, Path, Errs) when is_list(Value) ->
    case sget(items, Schema) of
        undefined -> Errs;
        ItemSchema ->
            {_, Acc} = lists:foldl(fun(V, {I, A}) ->
                IPath = <<Path/binary, "[", (integer_to_binary(I))/binary, "]">>,
                {I + 1, check(V, ItemSchema, IPath, A)}
            end, {0, Errs}, Value),
            Acc
    end;
check_items(_Value, _Schema, _Path, Errs) ->
    Errs.

check_property_count(Value, Schema, Path, Errs) when is_map(Value) ->
    N = map_size(Value),
    E1 = case sget(minProperties, Schema) of
        Min when is_integer(Min), N < Min ->
            [{Path, <<"fewer than minProperties">>} | Errs];
        _ -> Errs
    end,
    case sget(maxProperties, Schema) of
        Max when is_integer(Max), N > Max ->
            [{Path, <<"more than maxProperties">>} | E1];
        _ -> E1
    end;
check_property_count(_Value, _Schema, _Path, Errs) ->
    Errs.

check_additional_properties(Value, Schema, Path, Errs) when is_map(Value) ->
    case sget(additionalProperties, Schema) of
        undefined -> Errs;
        true      -> Errs;
        false ->
            Known = known_props(Schema),
            lists:foldl(fun(K, Acc) ->
                case lists:member(K, Known) of
                    true  -> Acc;
                    false -> [{join(Path, K),
                               <<"additional property not allowed">>} | Acc]
                end
            end, Errs, maps:keys(Value));
        Sub when is_map(Sub) ->
            Known = known_props(Schema),
            maps:fold(fun(K, V, Acc) ->
                case lists:member(K, Known) of
                    true  -> Acc;
                    false -> check(V, Sub, join(Path, K), Acc)
                end
            end, Errs, Value)
    end;
check_additional_properties(_Value, _Schema, _Path, Errs) ->
    Errs.

known_props(Schema) ->
    case sget(properties, Schema) of
        Props when is_map(Props) -> maps:keys(Props);
        _ -> []
    end.

check_array_constraints(Value, Schema, Path, Errs) when is_list(Value) ->
    Len = length(Value),
    E1 = case sget(minItems, Schema) of
        Min when is_integer(Min), Len < Min ->
            [{Path, <<"fewer than minItems">>} | Errs];
        _ -> Errs
    end,
    E2 = case sget(maxItems, Schema) of
        Max when is_integer(Max), Len > Max ->
            [{Path, <<"more than maxItems">>} | E1];
        _ -> E1
    end,
    case sget(uniqueItems, Schema) of
        true ->
            case length(lists:usort(Value)) =:= Len of
                true  -> E2;
                false -> [{Path, <<"items not unique">>} | E2]
            end;
        _ ->
            E2
    end;
check_array_constraints(_Value, _Schema, _Path, Errs) ->
    Errs.

%%====================================================================
%% Type checks
%%====================================================================

type_ok(<<"object">>, V)  -> is_map(V);
type_ok(<<"array">>, V)   -> is_list(V);
type_ok(<<"string">>, V)  -> is_binary(V);
type_ok(<<"number">>, V)  -> is_number(V);
type_ok(<<"integer">>, V) -> is_integer(V);
type_ok(<<"boolean">>, V) -> is_boolean(V);
type_ok(<<"null">>, V)    -> V =:= null;
type_ok(Type, V) when is_atom(Type) ->
    type_ok(atom_to_binary(Type), V);
type_ok(_Other, _V) ->
    true.

type_error(Type) when is_atom(Type) -> type_error(atom_to_binary(Type));
type_error(Type) -> <<"expected ", Type/binary>>.

type_error_list(Types) ->
    Names = lists:join(<<", ">>, [type_name(T) || T <- Types]),
    iolist_to_binary([<<"expected one of ">>, Names]).

type_name(T) when is_atom(T) -> atom_to_binary(T);
type_name(T) -> T.

%%====================================================================
%% Middleware
%%====================================================================

-spec call(livery_req:req(), livery_middleware:next(),
           #{body_schema := schema()}) -> livery_resp:resp().
call(Req, Next, #{body_schema := Schema}) ->
    case livery_ext:json(Req) of
        {ok, Decoded} ->
            case validate(Decoded, Schema) of
                ok ->
                    Next(livery_req:set_meta(body, Decoded, Req));
                {error, Errors} ->
                    livery_resp:json(422, encode_errors(Errors))
            end;
        {error, no_body} ->
            livery_resp:text(400, <<"request body required">>);
        {error, _} ->
            livery_resp:text(400, <<"malformed JSON body">>)
    end.

encode_errors(Errors) ->
    Items = [#{<<"path">> => P, <<"error">> => E} || {P, E} <- Errors],
    iolist_to_binary(json:encode(#{<<"errors">> => Items})).

%%====================================================================
%% Helpers
%%====================================================================

%% Accept atom or binary schema keys.
sget(Key, Schema) when is_atom(Key) ->
    case maps:find(Key, Schema) of
        {ok, V} -> V;
        error   -> maps:get(atom_to_binary(Key), Schema, undefined)
    end.

join(<<"$">>, Name) -> <<"$.", Name/binary>>;
join(Path, Name)    -> <<Path/binary, ".", Name/binary>>.
