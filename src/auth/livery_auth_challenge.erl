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
- a DPoP proof without a valid server nonce, when `dpop_nonce` is set:
  `401` with `error="use_dpop_nonce"` (RFC 9449 section 9);
- a valid token without the scopes the route needs: `403` with
  `error="insufficient_scope"` and the `scope` it needs;
- a token from a sign-in too weak or too old for the route: `401` with
  `error="insufficient_user_authentication"` and the `acr_values` and
  `max_age` to sign in again with (RFC 9470 section 3).

Options read from the middleware state: `realm`, `resource_metadata`
(the URL of the RFC 9728 document, sent as a parameter), and, when the
`DPoP` scheme is accepted (`livery_auth_binding:dpop_enabled/1`), a
second `DPoP` challenge listing the accepted `algs`. A challenge for
`Bearer` is left out when `binding => dpop` makes bearer tokens
useless. The error goes on the challenge of the scheme the client used.
With `dpop_nonce` set, every refusal also carries a fresh `DPoP-Nonce`,
so a client can retry at once.
""".

-export([respond/2, respond/3, header/3, with_nonce/2]).

-type outcome() ::
    missing_token
    | {invalid_token, binary()}
    | {invalid_dpop_proof, binary()}
    | {use_dpop_nonce, binary()}
    | {insufficient_user_authentication, binary()}
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
    Resp = livery_resp:with_header(
        <<"www-authenticate">>, header(Outcome, Scheme, Opts), livery_resp:text(Status, Body)
    ),
    with_nonce(Resp, Opts).

-doc "Add a fresh `DPoP-Nonce` to `Resp` when the options ask for nonces.".
-spec with_nonce(livery_resp:resp(), opts()) -> livery_resp:resp().
with_nonce(Resp, Opts) ->
    case livery_auth_binding:dpop_enabled(Opts) andalso livery_auth_dpop:nonce_enabled(Opts) of
        true -> livery_resp:with_header(<<"dpop-nonce">>, livery_auth_dpop:nonce(Opts), Resp);
        false -> Resp
    end.

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
        challenge(S, error_params(Outcome, S, Used, Opts) ++ scheme_params(S, Opts), Opts)
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
error_params(missing_token, _S, _Used, _Opts) ->
    [];
error_params({invalid_dpop_proof, _} = O, dpop, _Used, _Opts) ->
    params(O);
error_params({invalid_dpop_proof, _}, bearer, _Used, _Opts) ->
    [];
error_params({use_dpop_nonce, _} = O, dpop, _Used, _Opts) ->
    params(O);
error_params({use_dpop_nonce, _}, bearer, _Used, _Opts) ->
    [];
error_params({insufficient_user_authentication, _} = O, S, S, Opts) ->
    params(O) ++ livery_auth_stepup:required(Opts);
error_params(Outcome, S, S, _Opts) ->
    params(Outcome);
error_params(_Outcome, _S, _Used, _Opts) ->
    [].

scheme_params(dpop, Opts) ->
    Algs = maps:get(algorithms, Opts, livery_auth_jose:algorithms()),
    [{<<"algs">>, iolist_to_binary(lists:join(<<" ">>, Algs))}];
scheme_params(bearer, _Opts) ->
    [].

status_body(missing_token) -> {401, <<"missing token">>};
status_body({invalid_token, Detail}) -> {401, Detail};
status_body({invalid_dpop_proof, Detail}) -> {401, Detail};
status_body({use_dpop_nonce, Detail}) -> {401, Detail};
status_body({insufficient_user_authentication, Detail}) -> {401, Detail};
status_body({insufficient_scope, _}) -> {403, <<"insufficient scope">>}.

realm(#{realm := Realm}) when is_binary(Realm) -> [{<<"realm">>, Realm}];
realm(_) -> [].

metadata(#{resource_metadata := Url}) when is_binary(Url) -> [{<<"resource_metadata">>, Url}];
metadata(_) -> [].

params({invalid_token, Detail}) ->
    [{<<"error">>, <<"invalid_token">>}, {<<"error_description">>, Detail}];
params({invalid_dpop_proof, Detail}) ->
    [{<<"error">>, <<"invalid_dpop_proof">>}, {<<"error_description">>, Detail}];
params({insufficient_user_authentication, Detail}) ->
    [{<<"error">>, <<"insufficient_user_authentication">>}, {<<"error_description">>, Detail}];
params({use_dpop_nonce, Detail}) ->
    [{<<"error">>, <<"use_dpop_nonce">>}, {<<"error_description">>, Detail}];
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
