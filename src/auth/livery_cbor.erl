-module(livery_cbor).
-moduledoc """
A strict CBOR decoder (RFC 8949) for the data WebAuthn carries.

It reads what authenticators send in attestation objects and COSE keys:
unsigned and negative integers up to 64 bits, byte strings (as Erlang
binaries tagged `{bytes, Bin}`), text strings (as binaries), arrays
(lists), maps (Erlang maps, keys kept as decoded) and the simple values
`true`, `false` and `null`. Anything else is refused rather than guessed
at: indefinite lengths, tags, floats, other simple values, duplicate map
keys, nesting deeper than 16, invalid UTF-8 in a text string, or a
length that runs past the input.

`decode/1` returns the rest of the input after the first item, since a
WebAuthn `authData` holds a COSE key followed by optional extensions.

Deviations: the CTAP2 canonical form (shortest lengths, sorted map
keys) is not required; authenticators must produce it, but no relying
party step asks to check it. See AGENTS.md, Known deviations.
""".

-export([decode/1]).

-define(MAX_DEPTH, 16).

-type value() ::
    integer()
    | {bytes, binary()}
    | binary()
    | [value()]
    | #{value() => value()}
    | true
    | false
    | null.

-export_type([value/0]).

-doc "Decode the first CBOR item of `Bin`; returns it and the bytes after it.".
-spec decode(binary()) -> {ok, value(), binary()} | {error, term()}.
decode(Bin) when is_binary(Bin) ->
    try item(Bin, 0) of
        {Value, Rest} -> {ok, Value, Rest}
    catch
        error:{cbor, Reason} -> {error, Reason}
    end.

item(_Bin, Depth) when Depth > ?MAX_DEPTH ->
    fail(too_deep);
item(<<Major:3, Info:5, Rest/binary>>, Depth) ->
    major(Major, Info, Rest, Depth);
item(<<>>, _Depth) ->
    fail(truncated).

major(0, Info, Rest, _Depth) ->
    argument(Info, Rest);
major(1, Info, Rest, _Depth) ->
    {N, Rest1} = argument(Info, Rest),
    {-1 - N, Rest1};
major(2, Info, Rest, _Depth) ->
    {Bytes, Rest1} = string(Info, Rest),
    {{bytes, Bytes}, Rest1};
major(3, Info, Rest, _Depth) ->
    {Text, Rest1} = string(Info, Rest),
    case unicode:characters_to_binary(Text) of
        Text -> {Text, Rest1};
        _ -> fail(invalid_utf8)
    end;
major(4, Info, Rest, Depth) ->
    {N, Rest1} = argument(Info, Rest),
    items(N, Rest1, Depth + 1, []);
major(5, Info, Rest, Depth) ->
    {N, Rest1} = argument(Info, Rest),
    pairs(N, Rest1, Depth + 1, #{});
major(6, _Info, _Rest, _Depth) ->
    fail(tag);
major(7, 20, Rest, _Depth) ->
    {false, Rest};
major(7, 21, Rest, _Depth) ->
    {true, Rest};
major(7, 22, Rest, _Depth) ->
    {null, Rest};
major(7, _Info, _Rest, _Depth) ->
    fail(unsupported_simple_value).

%% The argument of an item: in the initial byte, or in the 1, 2, 4 or 8
%% bytes after it. 31 (indefinite length) and 28-30 (reserved) are refused.
argument(Info, Rest) when Info < 24 -> {Info, Rest};
argument(24, <<N:8, Rest/binary>>) -> {N, Rest};
argument(25, <<N:16, Rest/binary>>) -> {N, Rest};
argument(26, <<N:32, Rest/binary>>) -> {N, Rest};
argument(27, <<N:64, Rest/binary>>) -> {N, Rest};
argument(31, _Rest) -> fail(indefinite_length);
argument(Info, _Rest) when Info >= 28 -> fail(reserved);
argument(_Info, _Rest) -> fail(truncated).

string(Info, Rest) ->
    {Len, Rest1} = argument(Info, Rest),
    case Rest1 of
        <<S:Len/binary, Rest2/binary>> -> {S, Rest2};
        _ -> fail(truncated)
    end.

items(0, Rest, _Depth, Acc) ->
    {lists:reverse(Acc), Rest};
items(N, Rest, Depth, Acc) ->
    {V, Rest1} = item(Rest, Depth),
    items(N - 1, Rest1, Depth, [V | Acc]).

pairs(0, Rest, _Depth, Acc) ->
    {Acc, Rest};
pairs(N, Rest, Depth, Acc) ->
    {K, Rest1} = item(Rest, Depth),
    {V, Rest2} = item(Rest1, Depth),
    case maps:is_key(K, Acc) of
        true -> fail(duplicate_key);
        false -> pairs(N - 1, Rest2, Depth, Acc#{K => V})
    end.

-spec fail(term()) -> no_return().
fail(Reason) ->
    error({cbor, Reason}).
