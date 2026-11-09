-module(livery_auth_bearer).
-moduledoc """
Bearer-token authentication middleware.

Extracts the bearer token from the `Authorization` header,
verifies it with `livery_auth:verify/2`, and stores the validated
claims on the request as `meta(user, Claims)` (read it back with
`livery_ext:user/1`). A request without a token, or with an invalid
one, gets `401`; a valid token missing a required `scope` gets `403`.
Both carry the RFC 6750 `WWW-Authenticate` challenge built by
`livery_auth_challenge`.

State is the `livery_auth:verify_opts()` map (including `scope`,
`typ`, `profile` and `algorithms`) plus:

- `required => boolean()` (default `true`);
- `realm => binary()`, sent in the challenge;
- `jwks_uri => binary()`, to fetch and cache the keys instead of passing
  `keys`, with `fetch`, `ttl` and `min_refresh_interval` (milliseconds,
  default 30000) passed to `livery_auth_jwks`.

```erlang
{livery_auth_bearer, #{
    jwks_uri => <<"https://issuer.example/jwks">>,
    issuer   => <<"https://issuer.example">>,
    audience => <<"my-api">>,
    scope    => [<<"orders:read">>],
    realm    => <<"orders">>
}}
```

An unknown `kid` makes the middleware fetch the key set again, at most
once per `min_refresh_interval`, so a stream of tokens with made-up key
ids cannot turn into a stream of requests to the issuer.

When `required => false`, a missing token is allowed through (the
handler sees no `user` meta), but a present-but-invalid token is
still rejected.
""".
-behaviour(livery_middleware).

-export([call/3]).

-spec call(
    livery_req:req(),
    livery_middleware:next(),
    map()
) -> livery_resp:resp().
call(Req, Next, State) ->
    case livery_auth_binding:token(Req, State) of
        undefined ->
            case maps:get(required, State, true) of
                true -> livery_auth_challenge:respond(missing_token, State);
                false -> Next(Req)
            end;
        {Scheme, Token} ->
            Ctx = {Scheme, Token, State, Req, Next},
            case resolve_keys(State) of
                {ok, VerifyOpts} -> verify_with_rotation(VerifyOpts, Ctx);
                {error, _} -> invalid(<<"key resolution failed">>, Ctx)
            end
    end.

%% Verify; on a no_matching_key failure with a jwks_uri, refresh the
%% JWKS (rotation, throttled) and retry once before giving up.
verify_with_rotation(VerifyOpts, {_Scheme, Token, State, _Req, _Next} = Ctx) ->
    case livery_auth:verify(Token, VerifyOpts) of
        {error, no_matching_key} when is_map_key(jwks_uri, State) ->
            case refresh_keys(State) of
                {ok, VerifyOpts1} -> outcome(livery_auth:verify(Token, VerifyOpts1), Ctx);
                {error, _} -> invalid(<<"no matching key">>, Ctx)
            end;
        Result ->
            outcome(Result, Ctx)
    end.

%% A valid token still has to come from the client it is bound to; only
%% then is it worth saying which scopes it lacks.
outcome({ok, Claims}, {Scheme, Token, State, Req, Next}) ->
    case livery_auth_binding:check(Scheme, Token, Claims, Req, State) of
        ok ->
            case livery_auth:missing_scopes(Claims, maps:get(scope, State, [])) of
                [] ->
                    granted(Scheme, Next(livery_req:set_meta(user, Claims, Req)), State);
                Missing ->
                    livery_auth_challenge:respond({insufficient_scope, Missing}, Scheme, State)
            end;
        {error, Failure} ->
            livery_auth_challenge:respond(Failure, Scheme, State)
    end;
outcome({error, Reason}, Ctx) ->
    invalid(reason_text(Reason), Ctx).

invalid(Detail, {Scheme, _Token, State, _Req, _Next}) ->
    livery_auth_challenge:respond({invalid_token, Detail}, Scheme, State).

-spec resolve_keys(map()) -> {ok, livery_auth:verify_opts()} | {error, term()}.
resolve_keys(#{jwks_uri := Uri} = State) ->
    case livery_auth_jwks:keys(Uri, jwks_opts(State)) of
        {ok, Keys} -> {ok, verify_opts(State#{keys => Keys})};
        {error, _} = E -> E
    end;
resolve_keys(State) ->
    {ok, verify_opts(State)}.

refresh_keys(#{jwks_uri := Uri} = State) ->
    case livery_auth_jwks:maybe_refresh(Uri, jwks_opts(State)) of
        {ok, Keys} -> {ok, verify_opts(State#{keys => Keys})};
        {error, _} = E -> E
    end.

jwks_opts(State) ->
    maps:with([fetch, ttl, min_refresh_interval], State).

-spec verify_opts(map()) -> livery_auth:verify_opts().
verify_opts(State) ->
    maps:without(
        [jwks_uri, fetch, ttl, min_refresh_interval, scope], livery_auth_binding:stripped(State)
    ).

-spec reason_text(livery_auth:error_reason()) -> binary().
reason_text(expired) -> <<"token expired">>;
reason_text(not_yet_valid) -> <<"token not yet valid">>;
reason_text(bad_signature) -> <<"bad token signature">>;
reason_text(no_matching_key) -> <<"no matching key">>;
reason_text(malformed) -> <<"malformed token">>;
reason_text(invalid_json) -> <<"malformed token">>;
reason_text(audience_mismatch) -> <<"audience mismatch">>;
reason_text({issuer_mismatch, _}) -> <<"issuer mismatch">>;
reason_text({unsupported_alg, _}) -> <<"unsupported algorithm">>;
reason_text({unsupported_crit, _}) -> <<"unsupported critical header">>;
reason_text({invalid_typ, _}) -> <<"wrong token type">>;
reason_text({invalid_claim, _}) -> <<"malformed claim">>;
reason_text({missing_claim, _}) -> <<"missing claim">>;
reason_text({missing_option, _}) -> <<"verifier misconfigured">>.

%% A DPoP client gets the nonce for its next proof with every answer.
granted(dpop, Resp, State) -> livery_auth_challenge:with_nonce(Resp, State);
granted(bearer, Resp, _State) -> Resp.
