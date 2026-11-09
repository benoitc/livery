-module(livery_auth_challenge).
-moduledoc """
Bearer challenges and error responses (RFC 6750 section 3).

`respond/2` answers a request the bearer middlewares refuse:

- no token at all: `401` with `WWW-Authenticate: Bearer realm="..."`
  and no error code, as RFC 6750 3.1 asks;
- a token that is expired, malformed or otherwise invalid: `401` with
  `error="invalid_token"`;
- a valid token without the scopes the route needs: `403` with
  `error="insufficient_scope"` and the `scope` it needs.

`realm` is optional; leave it out and the challenge carries none.
""".

-export([respond/2, header/2]).

-type outcome() ::
    missing_token
    | {invalid_token, binary()}
    | {insufficient_scope, [binary()]}.

-type opts() :: #{realm => binary(), _ => _}.

-export_type([outcome/0, opts/0]).

-doc "The response for a refused request.".
-spec respond(outcome(), opts()) -> livery_resp:resp().
respond(Outcome, Opts) ->
    {Status, Body} = status_body(Outcome),
    livery_resp:with_header(
        <<"www-authenticate">>, header(Outcome, Opts), livery_resp:text(Status, Body)
    ).

-doc "The `WWW-Authenticate` value for a refused request.".
-spec header(outcome(), opts()) -> binary().
header(Outcome, Opts) ->
    Params = realm(Opts) ++ params(Outcome),
    case Params of
        [] -> <<"Bearer">>;
        _ -> iolist_to_binary([<<"Bearer ">>, lists:join(<<", ">>, [param(P) || P <- Params])])
    end.

status_body(missing_token) -> {401, <<"missing token">>};
status_body({invalid_token, Detail}) -> {401, Detail};
status_body({insufficient_scope, _}) -> {403, <<"insufficient scope">>}.

realm(#{realm := Realm}) when is_binary(Realm) -> [{<<"realm">>, Realm}];
realm(_) -> [].

params(missing_token) ->
    [];
params({invalid_token, Detail}) ->
    [{<<"error">>, <<"invalid_token">>}, {<<"error_description">>, Detail}];
params({insufficient_scope, Scopes}) ->
    [
        {<<"error">>, <<"insufficient_scope">>},
        {<<"scope">>, iolist_to_binary(lists:join(<<" ">>, Scopes))}
    ].

param({Name, Value}) ->
    [Name, <<"=\"">>, escape(Value), <<"\"">>].

%% quoted-string (RFC 9110 5.6.4): escape the quote and the backslash.
escape(Value) ->
    binary:replace(binary:replace(Value, <<"\\">>, <<"\\\\">>, [global]), <<"\"">>, <<"\\\"">>, [
        global
    ]).
