-module(users_list_handler).
-behaviour(livery_handler).

-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, State) ->
    %% Parse pagination from query string
    Page = parse_int(livery_helpers:get_qs_value(<<"page">>, Req, <<"1">>), 1),
    Limit = parse_int(livery_helpers:get_qs_value(<<"limit">>, Req, <<"20">>), 20),

    %% Fetch all users
    Users = ets:foldl(fun({_Id, User}, Acc) -> [User | Acc] end, [], users),

    %% Sort by ID
    SortedUsers = lists:sort(fun(#{id := A}, #{id := B}) -> A =< B end, Users),

    %% Apply pagination
    Offset = (Page - 1) * Limit,
    PagedUsers = lists:sublist(lists:nthtail(min(Offset, length(SortedUsers)), SortedUsers), Limit),

    livery_helpers:reply_json(200, #{
        data => PagedUsers,
        page => Page,
        limit => Limit,
        total => length(Users)
    }, State).

parse_int(Bin, Default) ->
    try binary_to_integer(Bin)
    catch _:_ -> Default
    end.
