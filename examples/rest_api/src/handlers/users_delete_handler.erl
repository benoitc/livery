-module(users_delete_handler).
-behaviour(livery_handler).

-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(_Req, Opts) ->
    UserIdBin = livery_helpers:binding(<<"id">>, Opts),

    case parse_user_id(UserIdBin) of
        {ok, UserId} ->
            case ets:lookup(users, UserId) of
                [{_, _User}] ->
                    ets:delete(users, UserId),
                    {reply, 204, [], Opts};
                [] ->
                    livery_helpers:reply_json(404, #{
                        error => <<"not_found">>,
                        message => <<"User not found">>
                    }, Opts)
            end;
        error ->
            livery_helpers:reply_json(400, #{
                error => <<"invalid_id">>,
                message => <<"User ID must be an integer">>
            }, Opts)
    end.

parse_user_id(Bin) ->
    try {ok, binary_to_integer(Bin)}
    catch _:_ -> error
    end.
