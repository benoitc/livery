%% @doc Pure Erlang HTTP/1.x request parser.
%%
%% Limits:
%% - Method: 16 bytes
%% - URI: 8KB
%% - Header name: 256 bytes
%% - Header value: 8KB
%% - Max headers: 100
-module(livery_h1_parse_erl).

-export([
    parse_request/1,
    parse_request/2,
    parse_chunk/1,
    parse_chunk/2,
    parse_trailers/1
]).

-include("livery.hrl").

-type parse_result() ::
    {ok, Method :: binary(), Path :: binary(), Qs :: binary(),
     Version :: {non_neg_integer(), non_neg_integer()},
     Headers :: [{binary(), binary()}], Rest :: binary()} |
    {more, binary()} |
    {error, term()}.

-type chunk_result() ::
    {ok, Data :: binary(), Rest :: binary()} |      %% Got a chunk
    {done, Rest :: binary()} |                       %% Got final chunk (size 0)
    {more, binary()} |                               %% Need more data
    {error, term()}.

-type trailers_result() ::
    {ok, Trailers :: [{binary(), binary()}], Rest :: binary()} |
    {more, binary()} |
    {error, term()}.

-type limits() :: #{
    max_method_size => pos_integer(),
    max_uri_size => pos_integer(),
    max_header_name_size => pos_integer(),
    max_header_value_size => pos_integer(),
    max_headers => pos_integer()
}.

-export_type([parse_result/0, chunk_result/0, trailers_result/0, limits/0]).

-spec parse_request(binary()) -> parse_result().
parse_request(Data) ->
    parse_request(Data, #{}).

-spec parse_request(binary(), limits()) -> parse_result().
parse_request(Data, Limits) ->
    MaxMethod = maps:get(max_method_size, Limits, ?MAX_METHOD_SIZE),
    MaxUri = maps:get(max_uri_size, Limits, ?MAX_URI_SIZE),
    MaxHeaderName = maps:get(max_header_name_size, Limits, ?MAX_HEADER_NAME_SIZE),
    MaxHeaderValue = maps:get(max_header_value_size, Limits, ?MAX_HEADER_VALUE_SIZE),
    MaxHeaders = maps:get(max_headers, Limits, ?MAX_HEADERS),
    parse_method(Data, <<>>, MaxMethod, MaxUri, MaxHeaderName, MaxHeaderValue, MaxHeaders).

%% Parse method (ends with space)
parse_method(<<>>, Acc, _MaxMethod, _MaxUri, _MaxHName, _MaxHVal, _MaxH) ->
    {more, Acc};
parse_method(<<" ", Rest/binary>>, Acc, _MaxMethod, MaxUri, MaxHName, MaxHVal, MaxH) when byte_size(Acc) > 0 ->
    parse_uri(Rest, <<>>, string:uppercase(Acc), MaxUri, MaxHName, MaxHVal, MaxH);
parse_method(<<C, Rest/binary>>, Acc, MaxMethod, MaxUri, MaxHName, MaxHVal, MaxH) when C >= $A, C =< $Z; C >= $a, C =< $z ->
    case byte_size(Acc) >= MaxMethod of
        true -> {error, method_too_long};
        false -> parse_method(Rest, <<Acc/binary, C>>, MaxMethod, MaxUri, MaxHName, MaxHVal, MaxH)
    end;
parse_method(<<_C, _/binary>>, _Acc, _MaxMethod, _MaxUri, _MaxHName, _MaxHVal, _MaxH) ->
    {error, invalid_method}.

%% Parse URI (ends with space)
parse_uri(<<>>, Acc, Method, _MaxUri, _MaxHName, _MaxHVal, _MaxH) ->
    {more, <<Method/binary, " ", Acc/binary>>};
parse_uri(<<" ", Rest/binary>>, Acc, Method, _MaxUri, MaxHName, MaxHVal, MaxH) when byte_size(Acc) > 0 ->
    {Path, Qs} = split_path_qs(Acc),
    parse_version(Rest, Method, Path, Qs, MaxHName, MaxHVal, MaxH);
parse_uri(<<C, Rest/binary>>, Acc, Method, MaxUri, MaxHName, MaxHVal, MaxH) when C > 32, C =/= 127 ->
    case byte_size(Acc) >= MaxUri of
        true -> {error, uri_too_long};
        false -> parse_uri(Rest, <<Acc/binary, C>>, Method, MaxUri, MaxHName, MaxHVal, MaxH)
    end;
parse_uri(<<_C, _/binary>>, _Acc, _Method, _MaxUri, _MaxHName, _MaxHVal, _MaxH) ->
    {error, invalid_uri}.

%% Split path and query string
split_path_qs(Uri) ->
    case binary:split(Uri, <<"?">>) of
        [Path] -> {Path, <<>>};
        [Path, Qs] -> {Path, Qs}
    end.

%% Parse HTTP version (HTTP/X.Y\r\n)
parse_version(<<"HTTP/1.1\r\n", Rest/binary>>, Method, Path, Qs, MaxHName, MaxHVal, MaxH) ->
    parse_headers(Rest, [], Method, Path, Qs, {1, 1}, MaxHName, MaxHVal, MaxH, 0);
parse_version(<<"HTTP/1.0\r\n", Rest/binary>>, Method, Path, Qs, MaxHName, MaxHVal, MaxH) ->
    parse_headers(Rest, [], Method, Path, Qs, {1, 0}, MaxHName, MaxHVal, MaxH, 0);
parse_version(<<"HTTP/", Major, ".", Minor, "\r\n", Rest/binary>>, Method, Path, Qs, MaxHName, MaxHVal, MaxH)
  when Major >= $0, Major =< $9, Minor >= $0, Minor =< $9 ->
    parse_headers(Rest, [], Method, Path, Qs, {Major - $0, Minor - $0}, MaxHName, MaxHVal, MaxH, 0);
parse_version(Data, _Method, _Path, _Qs, _MaxHName, _MaxHVal, _MaxH) when byte_size(Data) < 10 ->
    {more, Data};
parse_version(_, _Method, _Path, _Qs, _MaxHName, _MaxHVal, _MaxH) ->
    {error, invalid_version}.

%% Parse headers
parse_headers(<<"\r\n", Rest/binary>>, Acc, Method, Path, Qs, Version, _MaxHName, _MaxHVal, _MaxH, _Count) ->
    {ok, Method, Path, Qs, Version, lists:reverse(Acc), Rest};
parse_headers(<<>>, _Acc, _Method, _Path, _Qs, _Version, _MaxHName, _MaxHVal, _MaxH, _Count) ->
    {more, <<>>};
parse_headers(_Data, _Acc, _Method, _Path, _Qs, _Version, _MaxHName, _MaxHVal, MaxH, Count) when Count >= MaxH ->
    %% Too many headers
    {error, too_many_headers};
parse_headers(Data, Acc, Method, Path, Qs, Version, MaxHName, MaxHVal, MaxH, Count) ->
    case parse_header_name(Data, <<>>, MaxHName) of
        {more, _} ->
            {more, Data};
        {error, Reason} ->
            {error, Reason};
        {ok, Name, Rest1} ->
            case parse_header_value(Rest1, <<>>, MaxHVal) of
                {more, _} ->
                    {more, Data};
                {error, Reason} ->
                    {error, Reason};
                {ok, Value, Rest2} ->
                    LowerName = string:lowercase(Name),
                    parse_headers(Rest2, [{LowerName, Value} | Acc], Method, Path, Qs,
                                  Version, MaxHName, MaxHVal, MaxH, Count + 1)
            end
    end.

%% Parse header name (ends with colon)
parse_header_name(<<>>, _Acc, _MaxHName) ->
    {more, <<>>};
parse_header_name(<<":", Rest/binary>>, Acc, _MaxHName) when byte_size(Acc) > 0 ->
    {ok, Acc, skip_ows(Rest)};
parse_header_name(<<C, Rest/binary>>, Acc, MaxHName) when C > 32, C =/= $:, C =/= 127 ->
    case byte_size(Acc) >= MaxHName of
        true -> {error, header_name_too_long};
        false -> parse_header_name(Rest, <<Acc/binary, C>>, MaxHName)
    end;
parse_header_name(_, _, _) ->
    {error, invalid_header_name}.

%% Skip optional whitespace
skip_ows(<<" ", Rest/binary>>) -> skip_ows(Rest);
skip_ows(<<"\t", Rest/binary>>) -> skip_ows(Rest);
skip_ows(Data) -> Data.

%% Parse header value (ends with \r\n)
parse_header_value(<<>>, _Acc, _MaxHVal) ->
    {more, <<>>};
parse_header_value(<<"\r\n", Rest/binary>>, Acc, _MaxHVal) ->
    %% Trim trailing whitespace
    Value = trim_trailing_ws(Acc),
    {ok, Value, Rest};
parse_header_value(<<C, Rest/binary>>, Acc, MaxHVal) when C >= 32; C =:= $\t ->
    case byte_size(Acc) >= MaxHVal of
        true -> {error, header_value_too_long};
        false -> parse_header_value(Rest, <<Acc/binary, C>>, MaxHVal)
    end;
parse_header_value(_, _, _) ->
    {error, invalid_header_value}.

%% Trim trailing whitespace from binary
trim_trailing_ws(<<>>) ->
    <<>>;
trim_trailing_ws(Bin) ->
    case binary:last(Bin) of
        $  -> trim_trailing_ws(binary:part(Bin, 0, byte_size(Bin) - 1));
        $\t -> trim_trailing_ws(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end.

%% @doc Parse a chunk from chunked transfer encoding.
%% Returns {ok, ChunkData, Rest} for a data chunk,
%% {done, Rest} for the final zero-length chunk,
%% {more, Data} if more data is needed,
%% or {error, Reason} on parse error.
-spec parse_chunk(binary()) -> chunk_result().
parse_chunk(Data) ->
    parse_chunk(Data, ?MAX_CHUNK_SIZE).

-spec parse_chunk(binary(), pos_integer()) -> chunk_result().
parse_chunk(Data, MaxChunkSize) ->
    parse_chunk_size(Data, <<>>, MaxChunkSize).

%% Parse chunk size (hex) followed by optional extensions and CRLF
parse_chunk_size(<<>>, _Acc, _MaxSize) ->
    {more, <<>>};
parse_chunk_size(<<"\r\n", Rest/binary>>, Acc, MaxSize) when byte_size(Acc) > 0 ->
    case parse_hex(Acc) of
        {ok, 0} ->
            %% Final chunk - trailers follow
            {done, Rest};
        {ok, Size} when Size > MaxSize ->
            {error, chunk_too_large};
        {ok, Size} ->
            parse_chunk_data(Rest, Size);
        {error, Reason} ->
            {error, Reason}
    end;
parse_chunk_size(<<";", Rest/binary>>, Acc, MaxSize) when byte_size(Acc) > 0 ->
    %% Chunk extension - skip until CRLF
    skip_chunk_extensions(Rest, Acc, MaxSize);
parse_chunk_size(<<C, Rest/binary>>, Acc, MaxSize) when
        (C >= $0 andalso C =< $9) orelse
        (C >= $a andalso C =< $f) orelse
        (C >= $A andalso C =< $F) ->
    %% Limit chunk size line to 16 chars (huge chunks)
    case byte_size(Acc) >= 16 of
        true -> {error, chunk_size_too_long};
        false -> parse_chunk_size(Rest, <<Acc/binary, C>>, MaxSize)
    end;
parse_chunk_size(<<_C, _/binary>>, _Acc, _MaxSize) ->
    {error, invalid_chunk_size}.

%% Skip chunk extensions until CRLF
skip_chunk_extensions(<<>>, _SizeAcc, _MaxSize) ->
    {more, <<>>};
skip_chunk_extensions(<<"\r\n", Rest/binary>>, SizeAcc, MaxSize) ->
    case parse_hex(SizeAcc) of
        {ok, 0} -> {done, Rest};
        {ok, Size} when Size > MaxSize -> {error, chunk_too_large};
        {ok, Size} -> parse_chunk_data(Rest, Size);
        {error, Reason} -> {error, Reason}
    end;
skip_chunk_extensions(<<_, Rest/binary>>, SizeAcc, MaxSize) ->
    skip_chunk_extensions(Rest, SizeAcc, MaxSize).

%% Parse chunk data of known size + trailing CRLF
parse_chunk_data(Data, Size) when byte_size(Data) >= Size + 2 ->
    <<ChunkData:Size/binary, Rest/binary>> = Data,
    case Rest of
        <<"\r\n", Remaining/binary>> ->
            {ok, ChunkData, Remaining};
        <<"\r", _/binary>> ->
            %% Might have \r but not \n yet (incomplete)
            {more, Data};
        _ ->
            {error, invalid_chunk_terminator}
    end;
parse_chunk_data(Data, Size) when byte_size(Data) >= Size ->
    %% Have chunk data but not trailing CRLF yet
    <<_:Size/binary, Rest/binary>> = Data,
    case Rest of
        <<"\r", _/binary>> -> {more, Data};  %% Might be incomplete CRLF
        <<>> -> {more, Data};
        _ -> {error, invalid_chunk_terminator}
    end;
parse_chunk_data(_Data, _Size) ->
    {more, <<>>}.

%% Parse hex string to integer
parse_hex(Bin) ->
    try
        {ok, binary_to_integer(Bin, 16)}
    catch
        _:_ -> {error, invalid_chunk_size}
    end.

%% @doc Parse trailers after the final chunk.
%% Trailers are optional headers following the zero-length chunk.
-spec parse_trailers(binary()) -> trailers_result().
parse_trailers(Data) ->
    parse_trailers(Data, []).

parse_trailers(<<"\r\n", Rest/binary>>, Acc) ->
    {ok, lists:reverse(Acc), Rest};
parse_trailers(<<>>, _Acc) ->
    {more, <<>>};
parse_trailers(Data, Acc) ->
    case parse_header_name(Data, <<>>, ?MAX_HEADER_NAME_SIZE) of
        {more, _} ->
            {more, Data};
        {error, Reason} ->
            {error, Reason};
        {ok, Name, Rest1} ->
            case parse_header_value(Rest1, <<>>, ?MAX_HEADER_VALUE_SIZE) of
                {more, _} ->
                    {more, Data};
                {error, Reason} ->
                    {error, Reason};
                {ok, Value, Rest2} ->
                    LowerName = string:lowercase(Name),
                    parse_trailers(Rest2, [{LowerName, Value} | Acc])
            end
    end.
