-module(livery_auth_stepup).
-moduledoc """
Sign-in level and age checks (RFC 9470, OpenID Connect Core).

Some operations need more than a valid token: a sign-in with a stronger
method (`acr`, the authentication context class), or one recent enough
(`auth_time`). `check/2` compares a token's or ID token's claims with
what the options ask for:

- `acr_values => [binary()]`: `acr` must be one of them;
- `max_age => Seconds`: `auth_time` must be no older than that, give or
  take `leeway`.

A missing `acr` or `auth_time` does not meet the requirement. The token
middlewares answer a failure with `401` and
`error="insufficient_user_authentication"`, naming the `acr_values` and
`max_age` the client should sign in again with (RFC 9470 section 3);
`livery_auth_login` asks the provider for them.
""".

-export([check/2, required/1]).

-doc "Whether `Claims` meet the `acr_values` and `max_age` in `Opts`.".
-spec check(map(), map()) -> ok | {error, {insufficient_user_authentication, binary()}}.
check(Claims, Opts) ->
    Now = maps:get(now, Opts, os:system_time(second)),
    Leeway = maps:get(leeway, Opts, 0),
    case
        {
            acr_ok(maps:get(<<"acr">>, Claims, undefined), maps:get(acr_values, Opts, [])),
            age_ok(
                maps:get(<<"auth_time">>, Claims, undefined),
                maps:get(max_age, Opts, undefined),
                Now,
                Leeway
            )
        }
    of
        {true, true} ->
            ok;
        {false, _} ->
            {error, {insufficient_user_authentication, <<"a stronger sign-in is required">>}};
        {_, false} ->
            {error, {insufficient_user_authentication, <<"a more recent sign-in is required">>}}
    end.

-doc "The challenge parameters for the requirements in `Opts`.".
-spec required(map()) -> [{binary(), binary()}].
required(Opts) ->
    [
        {<<"acr_values">>, iolist_to_binary(lists:join(<<" ">>, A))}
     || A <- [maps:get(acr_values, Opts, [])], A =/= []
    ] ++
        [
            {<<"max_age">>, integer_to_binary(M)}
         || M <- [maps:get(max_age, Opts, undefined)], is_integer(M)
        ].

acr_ok(_Acr, []) -> true;
acr_ok(Acr, Allowed) when is_binary(Acr) -> lists:member(Acr, Allowed);
acr_ok(_Acr, _Allowed) -> false.

age_ok(_AuthTime, undefined, _Now, _Leeway) -> true;
age_ok(AuthTime, MaxAge, Now, Leeway) when is_number(AuthTime) -> Now - AuthTime =< MaxAge + Leeway;
age_ok(_AuthTime, _MaxAge, _Now, _Leeway) -> false.
