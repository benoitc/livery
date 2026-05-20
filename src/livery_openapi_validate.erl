-module(livery_openapi_validate).
-moduledoc """
Request validation against a JSON-Schema subset, plus a middleware
that rejects malformed request bodies with `422`.

`validate/2` checks a decoded JSON term (maps with binary keys,
lists, binaries, numbers, booleans, `null`) against a schema map.
Supported keywords: `type`, `required`, `properties`, `items`,
`enum`, `minimum`, `maximum`, `minLength`, `maxLength`. Schema keys
may be atoms or binaries. It is a pragmatic subset, not a complete
JSON Schema implementation.

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
    case sget(type, Schema) of
        undefined ->
            keywords(Value, Schema, Path, Errs);
        Type ->
            case type_ok(Type, Value) of
                true  -> keywords(Value, Schema, Path, Errs);
                false -> [{Path, type_error(Type)} | Errs]
            end
    end.

keywords(Value, Schema, Path, Errs) ->
    Errs1 = check_enum(Value, Schema, Path, Errs),
    Errs2 = check_bounds(Value, Schema, Path, Errs1),
    Errs3 = check_length(Value, Schema, Path, Errs2),
    Errs4 = check_required(Value, Schema, Path, Errs3),
    Errs5 = check_properties(Value, Schema, Path, Errs4),
    check_items(Value, Schema, Path, Errs5).

%%====================================================================
%% Keyword checks
%%====================================================================

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
    Errs1 = case sget(minimum, Schema) of
        undefined -> Errs;
        Min when Value < Min -> [{Path, <<"below minimum">>} | Errs];
        _ -> Errs
    end,
    case sget(maximum, Schema) of
        undefined -> Errs1;
        Max when Value > Max -> [{Path, <<"above maximum">>} | Errs1];
        _ -> Errs1
    end;
check_bounds(_Value, _Schema, _Path, Errs) ->
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
