%% @doc Content encoding utilities for HTTP compression.
%%
%% Supports gzip, deflate, and identity encodings per RFC 7231.
-module(livery_compress).

-export([
    decode/2,
    encode/2,
    supported_encodings/0,
    negotiate_encoding/1
]).

%% @doc Decode content with the given encoding.
%% Returns {ok, DecodedData} or {error, Reason}.
-spec decode(binary(), binary()) -> {ok, binary()} | {error, term()}.
decode(Data, <<"gzip">>) ->
    try
        {ok, zlib:gunzip(Data)}
    catch
        error:Reason -> {error, {gzip_decode_failed, Reason}}
    end;
decode(Data, <<"deflate">>) ->
    try
        Z = zlib:open(),
        ok = zlib:inflateInit(Z),
        Decompressed = iolist_to_binary(zlib:inflate(Z, Data)),
        ok = zlib:inflateEnd(Z),
        ok = zlib:close(Z),
        {ok, Decompressed}
    catch
        error:Reason -> {error, {deflate_decode_failed, Reason}}
    end;
decode(Data, <<"identity">>) ->
    {ok, Data};
decode(Data, <<>>) ->
    {ok, Data};
decode(_Data, Encoding) ->
    {error, {unsupported_encoding, Encoding}}.

%% @doc Encode content with the given encoding.
%% Returns {ok, EncodedData} or {error, Reason}.
-spec encode(binary(), binary()) -> {ok, binary()} | {error, term()}.
encode(Data, <<"gzip">>) ->
    try
        {ok, zlib:gzip(Data)}
    catch
        error:Reason -> {error, {gzip_encode_failed, Reason}}
    end;
encode(Data, <<"deflate">>) ->
    try
        Z = zlib:open(),
        ok = zlib:deflateInit(Z),
        Compressed = iolist_to_binary(zlib:deflate(Z, Data, finish)),
        ok = zlib:deflateEnd(Z),
        ok = zlib:close(Z),
        {ok, Compressed}
    catch
        error:Reason -> {error, {deflate_encode_failed, Reason}}
    end;
encode(Data, <<"identity">>) ->
    {ok, Data};
encode(Data, <<>>) ->
    {ok, Data};
encode(_Data, Encoding) ->
    {error, {unsupported_encoding, Encoding}}.

%% @doc List of supported content encodings.
-spec supported_encodings() -> [binary()].
supported_encodings() ->
    [<<"gzip">>, <<"deflate">>, <<"identity">>].

%% @doc Negotiate best encoding from Accept-Encoding header value.
%% Returns the best supported encoding or `identity' if none match.
-spec negotiate_encoding(binary()) -> binary().
negotiate_encoding(AcceptEncoding) ->
    %% Parse Accept-Encoding header
    %% Format: encoding [; q=weight], ...
    Encodings = parse_accept_encoding(AcceptEncoding),

    %% Sort by weight (descending)
    Sorted = lists:sort(fun({_, W1}, {_, W2}) -> W1 >= W2 end, Encodings),

    %% Find first supported encoding
    find_supported(Sorted).

%% Internal functions

parse_accept_encoding(Header) ->
    %% Split by comma
    Parts = binary:split(Header, <<",">>, [global, trim_all]),
    lists:filtermap(fun parse_encoding_part/1, Parts).

parse_encoding_part(Part) ->
    %% Trim whitespace
    Trimmed = string:trim(Part),
    case binary:split(Trimmed, <<";">>) of
        [Encoding] ->
            {true, {string:lowercase(Encoding), 1.0}};
        [Encoding, Params] ->
            Weight = parse_weight(Params),
            {true, {string:lowercase(Encoding), Weight}};
        _ ->
            false
    end.

parse_weight(Params) ->
    %% Look for q= parameter
    case binary:match(Params, <<"q=">>) of
        {Start, _} ->
            WeightStr = binary:part(Params, Start + 2, byte_size(Params) - Start - 2),
            %% Parse as float
            try
                case binary:match(WeightStr, <<".">>) of
                    nomatch ->
                        float(binary_to_integer(string:trim(WeightStr)));
                    _ ->
                        binary_to_float(string:trim(WeightStr))
                end
            catch
                _:_ -> 1.0
            end;
        nomatch ->
            1.0
    end.

find_supported([]) ->
    <<"identity">>;
find_supported([{Encoding, Weight} | Rest]) ->
    case Weight > 0 andalso lists:member(Encoding, supported_encodings()) of
        true -> Encoding;
        false -> find_supported(Rest)
    end.
