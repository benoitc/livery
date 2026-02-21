-module(users_update_handler).
-behaviour(livery_handler).

-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, Opts) ->
    UserIdBin = livery_helpers:binding(<<"id">>, Opts),

    case parse_user_id(UserIdBin) of
        {ok, UserId} ->
            case ets:lookup(users, UserId) of
                [{_, ExistingUser}] ->
                    update_user(Req, UserId, ExistingUser, Opts);
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

update_user(Req, UserId, ExistingUser, Opts) ->
    case livery_helpers:json_body(Req) of
        {ok, Updates} when is_map(Updates) ->
            %% Only allow updating name and email
            AllowedUpdates = maps:with([<<"name">>, <<"email">>], Updates),
            UpdatedUser = maps:merge(ExistingUser, AllowedUpdates),

            %% Store updated user
            ets:insert(users, {UserId, UpdatedUser}),

            livery_helpers:reply_json(200, UpdatedUser, Opts);
        {ok, _} ->
            livery_helpers:reply_json(400, #{
                error => <<"invalid_body">>,
                message => <<"Request body must be a JSON object">>
            }, Opts);
        {error, _} ->
            livery_helpers:reply_json(400, #{
                error => <<"invalid_json">>,
                message => <<"Request body must be valid JSON">>
            }, Opts)
    end.

parse_user_id(Bin) ->
    try {ok, binary_to_integer(Bin)}
    catch _:_ -> error
    end.
