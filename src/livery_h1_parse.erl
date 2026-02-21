%% @doc HTTP/1.x parser facade.
%%
%% Delegates to either the pure Erlang parser or a NIF parser (when available).
-module(livery_h1_parse).

-export([
    parse_request/1,
    parse_request/2
]).

-type parse_result() :: livery_h1_parse_erl:parse_result().
-type limits() :: livery_h1_parse_erl:limits().

-export_type([parse_result/0, limits/0]).

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
