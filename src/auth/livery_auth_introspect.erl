-module(livery_auth_introspect).
-moduledoc """
OAuth 2.0 token introspection middleware (RFC 7662).

Verifies opaque bearer tokens that cannot be checked locally by
POSTing them to the authorization server's introspection endpoint
and trusting the `active` field of the JSON response. On success
the full introspection response (claims such as `scope`,
`client_id`, `username`, `sub`, `exp`) is stored as
`meta(user, _)` (read it back with `livery_ext:user/1`). A missing,
inactive or foreign token gets `401`, an active one without the
required `scope` gets `403`, both with the RFC 6750 challenge from
`livery_auth_challenge`.

Use this for reference/opaque tokens; for self-contained JWTs
prefer local verification with `livery_auth_bearer`.

State:

```erlang
{livery_auth_introspect, #{
    endpoint      => <<"https://issuer.example/oauth/introspect">>,
    client_id     => <<"my-api">>,
    client_secret => <<"s3cret">>,
    audience      => <<"https://api.example">>,
    scope         => [<<"orders:read">>],
    realm         => <<"orders">>,
    required      => true
}}
```

This resource server authenticates to the introspection endpoint
(RFC 7662 2.1) the way the token client does (`livery_auth_token`):

- by default, HTTP Basic with `client_id` and `client_secret`, each
  form-encoded first (RFC 6749 2.3.1), or no client authentication when
  they are not both set;
- `client_auth => client_secret_post`: the two in the form body;
- `client_auth => private_key_jwt`: a signed assertion (RFC 7523, as
  updated by RFC 10070), with `private_key => {Alg, Key}`, an optional
  `key_id`, and the authorization server's `issuer` as its audience.

Mutual TLS (`tls_client_auth`) needs a client certificate on the
outbound connection; use your own `fetch` for it.

`audience` and `scope` are checked against the response's `aud` and
`scope` when set.

Deviations: responses are not cached, so every request asks the
authorization server; cache in your own middleware if you need to. See
AGENTS.md, Known deviations. The HTTP call is
pluggable via `fetch => fun((Url, Headers, Body) -> {ok, Status,
Body} | {error, _})`; the default goes through `livery_client`
(`livery_auth:client/0`), verifying the server's certificate.
""".
-behaviour(livery_middleware).

-export([call/3, introspect/2, default_fetch/3]).

-export_type([opts/0, error_reason/0]).

-type opts() :: #{
    endpoint := binary(),
    client_id => binary(),
    client_secret => binary(),
    client_auth => client_secret_basic | client_secret_post | private_key_jwt | none,
    private_key => {binary(), term()},
    key_id => binary(),
    issuer => binary(),
    assertion_audience => issuer | token_endpoint,
    token_type_hint => binary(),
    audience => binary() | [binary()],
    scope => [binary()],
    realm => binary(),
    required => boolean(),
    fetch => fetch_fun()
}.

-type fetch_fun() ::
    fun(
        (binary(), [{binary(), binary()}], binary()) ->
            {ok, non_neg_integer(), binary()} | {error, term()}
    ).

-type error_reason() ::
    inactive
    | audience_mismatch
    | {insufficient_scope, [binary()]}
    | invalid_response
    | invalid_json
    | {http_status, non_neg_integer()}
    | term().

%%====================================================================
%% Middleware
%%====================================================================

-spec call(livery_req:req(), livery_middleware:next(), map()) ->
    livery_resp:resp().
call(Req, Next, State) ->
    case livery_auth_binding:token(Req, State) of
        undefined ->
            case maps:get(required, State, true) of
                true -> livery_auth_challenge:respond(missing_token, State);
                false -> Next(Req)
            end;
        {Scheme, Token} ->
            %% Scopes are checked once the token is known to come from the
            %% client it is bound to.
            case introspect(Token, maps:remove(scope, State)) of
                {ok, Claims} ->
                    authorize(Scheme, Token, Claims, Req, Next, State);
                {error, _} ->
                    livery_auth_challenge:respond(
                        {invalid_token, <<"invalid token">>}, Scheme, State
                    )
            end
    end.

authorize(Scheme, Token, Claims, Req, Next, State) ->
    case livery_auth_binding:check(Scheme, Token, Claims, Req, State) of
        ok ->
            case livery_auth:authorized(Claims, State) of
                ok ->
                    livery_auth_challenge:granted(
                        Scheme, Next(livery_req:set_meta(user, Claims, Req)), State
                    );
                {error, Outcome} ->
                    livery_auth_challenge:respond(Outcome, Scheme, State)
            end;
        {error, Failure} ->
            livery_auth_challenge:respond(Failure, Scheme, State)
    end.

%%====================================================================
%% Introspection
%%====================================================================

-doc """
Introspect a token at the configured endpoint.

Returns the introspection response map when the token is `active`,
`{error, inactive}` when it is not, and other `{error, _}` reasons
on transport or decoding failure.
""".
-spec introspect(binary(), opts()) -> {ok, map()} | {error, error_reason()}.
introspect(Token, Opts) ->
    Endpoint = maps:get(endpoint, Opts),
    Fetch = maps:get(fetch, Opts, fun default_fetch/3),
    case client_auth(Opts) of
        {ok, AuthHeaders, AuthForm} ->
            Headers = AuthHeaders ++ base_headers(),
            case Fetch(Endpoint, Headers, form_body(Token, Opts, AuthForm)) of
                {ok, 200, Body} -> check(parse_response(Body), Opts);
                {ok, Code, _Body} -> {error, {http_status, Code}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% RFC 7662 2.1: the protected resource authenticates to the endpoint.
%% The methods are the token client's (livery_auth_token). Without
%% `client_auth', Basic when both credentials are set, nothing otherwise.
%% The endpoint stands in for the token endpoint in the legacy
%% `assertion_audience => token_endpoint' mode.
-spec client_auth(opts()) ->
    {ok, [{binary(), binary()}], [{binary(), binary()}]} | {error, term()}.
client_auth(#{client_auth := tls_client_auth}) ->
    {error, {unsupported_client_auth, tls_client_auth}};
client_auth(#{client_auth := _, client_id := _} = Opts) ->
    livery_auth_token:client_auth(Opts#{token_endpoint => maps:get(endpoint, Opts)});
client_auth(#{client_auth := _}) ->
    {error, {missing_option, client_id}};
client_auth(#{client_id := Id, client_secret := Secret} = Opts) when
    is_binary(Id), is_binary(Secret)
->
    livery_auth_token:client_auth(Opts#{client_auth => client_secret_basic});
client_auth(_Opts) ->
    {ok, [], []}.

-spec parse_response(binary()) -> {ok, map()} | {error, error_reason()}.
parse_response(Body) ->
    try json:decode(Body) of
        #{<<"active">> := true} = Claims -> {ok, Claims};
        #{<<"active">> := false} -> {error, inactive};
        _ -> {error, invalid_response}
    catch
        _:_ -> {error, invalid_json}
    end.

%% RFC 7662 4: the resource server decides whether an active token is
%% meant for it and grants what the request needs.
check({ok, Claims}, Opts) ->
    Aud = maps:get(audience, Opts, undefined),
    case
        Aud =:= undefined orelse
            livery_auth:audience_matches(maps:get(<<"aud">>, Claims, undefined), Aud)
    of
        false ->
            {error, audience_mismatch};
        true ->
            case livery_auth:missing_scopes(Claims, maps:get(scope, Opts, [])) of
                [] -> {ok, Claims};
                Missing -> {error, {insufficient_scope, Missing}}
            end
    end;
check(Error, _Opts) ->
    Error.

-spec form_body(binary(), opts(), [{binary(), binary()}]) -> binary().
form_body(Token, Opts, AuthForm) ->
    Hint =
        case maps:get(token_type_hint, Opts, undefined) of
            undefined -> [];
            H -> [{<<"token_type_hint">>, H}]
        end,
    iolist_to_binary(uri_string:compose_query([{<<"token">>, Token}] ++ Hint ++ AuthForm)).

-spec base_headers() -> [{binary(), binary()}].
base_headers() ->
    [
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
        {<<"accept">>, <<"application/json">>}
    ].

%%====================================================================
%% Default HTTP fetcher
%%====================================================================

-doc """
Default introspection POST, through `livery_client` (`livery_auth:client/0`),
verifying the server's certificate. Waits 5 seconds for the answer.
""".
-spec default_fetch(binary(), [{binary(), binary()}], binary()) ->
    {ok, non_neg_integer(), binary()} | {error, term()}.
default_fetch(Url, Headers, Body) ->
    Req = #{headers => Headers, body => {full, Body}, timeout => 5000},
    case livery_client:request(livery_auth:client(), post, Url, Req) of
        {ok, Resp} ->
            {ok, livery_client:status(Resp), full_body(Resp)};
        {error, _} = Error ->
            Error
    end.

-spec full_body(livery_client:response()) -> binary().
full_body(Resp) ->
    case livery_client:body(Resp) of
        {full, Body} -> iolist_to_binary(Body);
        _ -> <<>>
    end.
