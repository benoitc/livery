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
    parse_request/2
]).

-include("livery.hrl").

-type parse_result() ::
    {ok, Method :: binary(), Path :: binary(), Qs :: binary(),
     Version :: {non_neg_integer(), non_neg_integer()},
     Headers :: [{binary(), binary()}], Rest :: binary()} |
    {more, binary()} |
    {error, term()}.

-type limits() :: #{
    max_method_size => pos_integer(),
    max_uri_size => pos_integer(),
    max_header_name_size => pos_integer(),
    max_header_value_size => pos_integer(),
    max_headers => pos_integer()
}.

-export_type([parse_result/0, limits/0]).

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
