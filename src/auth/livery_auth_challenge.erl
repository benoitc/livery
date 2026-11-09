-module(livery_auth_challenge).
-moduledoc """
Authentication challenges and error responses for the token
middlewares (RFC 6750 section 3, RFC 9449 section 7.1, RFC 9728
section 5.1).

`respond/2` answers a request the middlewares refuse:

- no token at all: `401` with a challenge and no error code, as
  RFC 6750 3.1 asks;
- a token that is expired, malformed or otherwise invalid: `401` with
  `error="invalid_token"`;
- a missing or bad DPoP proof: `401` with `error="invalid_dpop_proof"`
  on the `DPoP` challenge;
- a valid token without the scopes the route needs: `403` with
  `error="insufficient_scope"` and the `scope` it needs.

Options read from the middleware state: `realm`, `resource_metadata`
(the URL of the RFC 9728 document, sent as a parameter), and, when the
`DPoP` scheme is accepted (`livery_auth_binding:dpop_enabled/1`), a
second `DPoP` challenge listing the accepted `algs`. A challenge for
`Bearer` is left out when `binding => dpop` makes bearer tokens
useless. The error goes on the challenge of the scheme the client used.
""".

-export([respond/2, respond/3, header/3]).

-type outcome() ::
    missing_token
    | {invalid_token, binary()}
    | {invalid_dpop_proof, binary()}
    | {insufficient_scope, [binary()]}.

-type opts() :: #{realm => binary(), resource_metadata => binary(), _ => _}.

-export_type([outcome/0, opts/0]).

-doc "`respond/3` for a request sent with the `Bearer` scheme.".
-spec respond(outcome(), opts()) -> livery_resp:resp().
respond(Outcome, Opts) ->
    respond(Outcome, bearer, Opts).

-doc "The response for a request sent with `Scheme` and refused with `Outcome`.".
-spec respond(outcome(), bearer | dpop, opts()) -> livery_resp:resp().
respond(Outcome, Scheme, Opts) ->
    {Status, Body} = status_body(Outcome),
    livery_resp:with_header(
        <<"www-authenticate">>, header(Outcome, Scheme, Opts), livery_resp:text(Status, Body)
    ).

-doc "The `WWW-Authenticate` value for the refused request.".
-spec header(outcome(), bearer | dpop, opts()) -> binary().
header(Outcome, Scheme, Opts) ->
    Schemes = schemes(Opts),
    %% A scheme the middleware does not advertise still gets its error,
    %% on the first challenge sent.
    Used =
        case lists:member(Scheme, Schemes) of
            true -> Scheme;
            false -> hd(Schemes)
        end,
    Challenges = [
        challenge(S, error_params(Outcome, S, Used) ++ scheme_params(S, Opts), Opts)
     || S <- Schemes
    ],
    iolist_to_binary(lists:join(<<", ">>, Challenges)).

schemes(Opts) ->
    Bearer = [bearer || maps:get(binding, Opts, none) =/= dpop],
    Dpop = [dpop || livery_auth_binding:dpop_enabled(Opts)],
    Bearer ++ Dpop.

challenge(Scheme, Params, Opts) ->
    All = realm(Opts) ++ Params ++ metadata(Opts),
    Name = scheme_name(Scheme),
    case All of
        [] -> Name;
        _ -> [Name, $\s, lists:join(<<", ">>, [param(P) || P <- All])]
    end.

scheme_name(bearer) -> <<"Bearer">>;
scheme_name(dpop) -> <<"DPoP">>.

%% The error belongs to the scheme the client used; a DPoP proof error is
%% only meaningful on the DPoP challenge.
error_params(missing_token, _S, _Used) -> [];
error_params({invalid_dpop_proof, _} = O, dpop, _Used) -> params(O);
error_params({invalid_dpop_proof, _}, bearer, _Used) -> [];
error_params(Outcome, S, S) -> params(Outcome);
error_params(_Outcome, _S, _Used) -> [].

scheme_params(dpop, Opts) ->
    Algs = maps:get(algorithms, Opts, livery_auth_jose:algorithms()),
    [{<<"algs">>, iolist_to_binary(lists:join(<<" ">>, Algs))}];
scheme_params(bearer, _Opts) ->
    [].

status_body(missing_token) -> {401, <<"missing token">>};
status_body({invalid_token, Detail}) -> {401, Detail};
status_body({invalid_dpop_proof, Detail}) -> {401, Detail};
status_body({insufficient_scope, _}) -> {403, <<"insufficient scope">>}.

realm(#{realm := Realm}) when is_binary(Realm) -> [{<<"realm">>, Realm}];
realm(_) -> [].

metadata(#{resource_metadata := Url}) when is_binary(Url) -> [{<<"resource_metadata">>, Url}];
metadata(_) -> [].

params({invalid_token, Detail}) ->
    [{<<"error">>, <<"invalid_token">>}, {<<"error_description">>, Detail}];
params({invalid_dpop_proof, Detail}) ->
    [{<<"error">>, <<"invalid_dpop_proof">>}, {<<"error_description">>, Detail}];
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
