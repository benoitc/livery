%% @doc NIF wrapper for picohttpparser.
%%
%% Provides fast HTTP/1.x request parsing using picohttpparser.
%% Falls back to pure Erlang implementation if NIF is not available.
-module(livery_h1_parse_nif).

-export([parse_request_nif/1]).

-on_load(init/0).

-define(APPNAME, livery).
-define(LIBNAME, livery_h1_parse_nif).

init() ->
    SoName = case code:priv_dir(?APPNAME) of
        {error, bad_name} ->
            case filelib:is_dir(filename:join(["..", priv])) of
                true ->
                    filename:join(["..", priv, ?LIBNAME]);
                _ ->
                    filename:join([priv, ?LIBNAME])
            end;
        Dir ->
            filename:join(Dir, ?LIBNAME)
    end,
    erlang:load_nif(SoName, 0).

%% @doc Parse HTTP request using NIF.
%% Returns {ok, Method, Path, Qs, Version, Headers, Rest} |
%%         {more, Data} | {error, Reason}
-spec parse_request_nif(binary()) ->
    {ok, binary(), binary(), binary(), {1, 0|1}, [{binary(), binary()}], binary()} |
    {more, binary()} |
    {error, atom()}.
parse_request_nif(_Data) ->
    erlang:nif_error(nif_not_loaded).
