-module(users_create_handler).
-behaviour(livery_handler).

-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(Req, State) ->
    case livery_helpers:json_body(Req) of
        {ok, #{<<"name">> := Name, <<"email">> := Email}}
          when is_binary(Name), is_binary(Email) ->
            %% Validate inputs
            case validate_user(Name, Email) of
                ok ->
                    %% Generate new ID
                    Id = ets:info(users, size) + 1,
                    User = #{id => Id, name => Name, email => Email},

                    %% Store user
                    ets:insert(users, {Id, User}),

                    livery_helpers:reply_json(201, User, State);
                {error, Reason} ->
                    livery_helpers:reply_json(422, #{
                        error => <<"validation_error">>,
                        message => Reason
                    }, State)
            end;
        {ok, _} ->
            livery_helpers:reply_json(400, #{
                error => <<"validation_error">>,
                message => <<"name and email are required">>
            }, State);
        {error, no_body} ->
            livery_helpers:reply_json(400, #{
                error => <<"missing_body">>,
                message => <<"Request body is required">>
            }, State);
        {error, _} ->
            livery_helpers:reply_json(400, #{
                error => <<"invalid_json">>,
                message => <<"Request body must be valid JSON">>
            }, State)
    end.

validate_user(Name, Email) ->
    case byte_size(Name) of
        N when N < 1 -> {error, <<"Name cannot be empty">>};
        N when N > 100 -> {error, <<"Name is too long">>};
        _ ->
            case binary:match(Email, <<"@">>) of
                nomatch -> {error, <<"Invalid email format">>};
                _ -> ok
            end
    end.
