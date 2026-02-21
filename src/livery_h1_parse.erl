%% @doc HTTP/1.x parser facade.
%%
%% Delegates to either the pure Erlang parser or a NIF parser (when available).
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
-spec parse_request(binary()) -> parse_result().
parse_request(Data) ->
    parse_request(Data, #{}).

%% @doc Parse an HTTP/1.x request with custom limits.
-spec parse_request(binary(), limits()) -> parse_result().
parse_request(Data, Limits) ->
    %% For now, always use the pure Erlang parser.
    %% In Phase 4, we can add NIF support here.
    livery_h1_parse_erl:parse_request(Data, Limits).

%% @doc Parse a chunk from chunked transfer encoding.
-spec parse_chunk(binary()) -> chunk_result().
parse_chunk(Data) ->
    livery_h1_parse_erl:parse_chunk(Data).

%% @doc Parse trailers after the final chunk.
-spec parse_trailers(binary()) -> trailers_result().
parse_trailers(Data) ->
    livery_h1_parse_erl:parse_trailers(Data).
