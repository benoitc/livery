%% @doc HTTP/1.x parser facade.
%%
%% Delegates to either the NIF parser (picohttpparser) or the pure Erlang parser.
%% NIF is used when available for better performance.
-module(livery_h1_parse).

-export([
    parse_request/1,
    parse_request/2,
    parse_chunk/1,
    parse_trailers/1
]).

-type parse_result() :: livery_h1_parse_erl:parse_result().
-type chunk_result() :: livery_h1_parse_erl:chunk_result().
-type trailers_result() :: livery_h1_parse_erl:trailers_result().
-type limits() :: livery_h1_parse_erl:limits().

-export_type([parse_result/0, chunk_result/0, trailers_result/0, limits/0]).

%% @doc Parse an HTTP/1.x request.
%% Tries NIF parser first, falls back to pure Erlang.
-spec parse_request(binary()) -> parse_result().
parse_request(Data) ->
    parse_request(Data, #{}).

%% @doc Parse an HTTP/1.x request with custom limits.
%% Tries NIF parser first, falls back to pure Erlang.
-spec parse_request(binary(), limits()) -> parse_result().
parse_request(Data, Limits) ->
    %% Try NIF parser first (faster)
    case nif_available() of
        true ->
            case livery_h1_parse_nif:parse_request_nif(Data) of
                {ok, Method, Path, Qs, Version, Headers, Rest} ->
                    %% NIF succeeded - validate limits if any
                    case validate_limits(Method, Path, Headers, Limits) of
                        ok ->
                            {ok, Method, Path, Qs, Version, Headers, Rest};
                        {error, _} = Error ->
                            Error
                    end;
                {more, _} = More ->
                    More;
                {error, _Reason} ->
                    %% NIF parse error - use Erlang parser for specific error message
                    %% (Erlang will also fail but with detailed error like invalid_method)
                    livery_h1_parse_erl:parse_request(Data, Limits)
            end;
        false ->
            %% NIF not available - use Erlang parser
            livery_h1_parse_erl:parse_request(Data, Limits)
    end.

%% @doc Parse a chunk from chunked transfer encoding.
-spec parse_chunk(binary()) -> chunk_result().
parse_chunk(Data) ->
    livery_h1_parse_erl:parse_chunk(Data).

%% @doc Parse trailers after the final chunk.
-spec parse_trailers(binary()) -> trailers_result().
parse_trailers(Data) ->
    livery_h1_parse_erl:parse_trailers(Data).

%%====================================================================
%% Internal
%%====================================================================

%% @private Check if NIF is available.
-spec nif_available() -> boolean().
nif_available() ->
    case persistent_term:get({?MODULE, nif_available}, undefined) of
        undefined ->
            Available = check_nif_available(),
            persistent_term:put({?MODULE, nif_available}, Available),
            Available;
        Available ->
            Available
    end.

%% @private Actually check if NIF is available.
check_nif_available() ->
    try
        livery_h1_parse_nif:parse_request_nif(<<>>),
        true
    catch
        error:undef -> false;
        error:nif_not_loaded -> false;
        _:_ -> true  % NIF loaded but returned error (expected for empty input)
    end.

%% @private Validate limits after NIF parsing.
validate_limits(Method, Path, Headers, Limits) ->
    MaxMethodLen = maps:get(max_method_size, Limits, 16),
    MaxPathLen = maps:get(max_uri_size, Limits, 8192),
    MaxHeaderName = maps:get(max_header_name_size, Limits, 256),
    MaxHeaderValue = maps:get(max_header_value_size, Limits, 8192),
    MaxHeaders = maps:get(max_headers, Limits, 100),
    case validate_method_chars(Method) of
        ok ->
            case validate_path_chars(Path) of
                ok ->
                    if
                        byte_size(Method) > MaxMethodLen ->
                            {error, method_too_long};
                        byte_size(Path) > MaxPathLen ->
                            {error, uri_too_long};
                        length(Headers) > MaxHeaders ->
                            {error, too_many_headers};
                        true ->
                            validate_header_sizes(Headers, MaxHeaderName, MaxHeaderValue)
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @private Validate method contains only alphabetic chars.
validate_method_chars(<<>>) ->
    ok;
validate_method_chars(<<C, Rest/binary>>) when C >= $A, C =< $Z; C >= $a, C =< $z ->
    validate_method_chars(Rest);
validate_method_chars(_) ->
    {error, invalid_method}.

%% @private Validate path doesn't contain control characters.
validate_path_chars(<<>>) ->
    ok;
validate_path_chars(<<C, Rest/binary>>) when C > 32, C =/= 127 ->
    validate_path_chars(Rest);
validate_path_chars(_) ->
    {error, invalid_uri}.

%% @private Validate header name and value sizes.
validate_header_sizes([], _MaxName, _MaxValue) ->
    ok;
validate_header_sizes([{Name, Value} | Rest], MaxName, MaxValue) ->
    if
        byte_size(Name) > MaxName ->
            {error, header_name_too_long};
        byte_size(Value) > MaxValue ->
            {error, header_value_too_long};
        true ->
            validate_header_sizes(Rest, MaxName, MaxValue)
    end.
