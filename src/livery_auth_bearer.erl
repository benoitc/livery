-module(livery_auth_bearer).
-moduledoc """
Bearer-token authentication middleware.

Extracts the bearer token from the `Authorization` header,
verifies it with `livery_auth:verify/2`, and stores the validated
claims on the request as `meta(user, Claims)` (read it back with
`livery_ext:user/1`). On any failure it short-circuits with
`401 Unauthorized` and a `WWW-Authenticate: Bearer` header.

State is the `livery_auth:verify_opts()` map plus an optional
`required => boolean()` (default `true`):

```erlang
{livery_auth_bearer, #{
    keys     => Jwks,
    issuer   => <<"https://issuer.example">>,
    audience => <<"my-api">>
}}
```

When `required => false`, a missing token is allowed through (the
handler sees no `user` meta), but a present-but-invalid token is
still rejected.
""".
-behaviour(livery_middleware).

-export([call/3]).

-spec call(livery_req:req(), livery_middleware:next(),
           map()) -> livery_resp:resp().
call(Req, Next, State) ->
    case livery_ext:bearer_token(Req) of
        undefined ->
            case maps:get(required, State, true) of
                true  -> unauthorized(<<"missing token">>);
                false -> Next(Req)
            end;
        Token ->
            case livery_auth:verify(Token, verify_opts(State)) of
                {ok, Claims} ->
                    Next(livery_req:set_meta(user, Claims, Req));
                {error, Reason} ->
                    unauthorized(reason_text(Reason))
            end
    end.

-spec verify_opts(map()) -> livery_auth:verify_opts().
verify_opts(State) ->
    maps:without([required], State).

-spec unauthorized(binary()) -> livery_resp:resp().
unauthorized(Detail) ->
    Resp = livery_resp:text(401, Detail),
    livery_resp:with_header(<<"www-authenticate">>, <<"Bearer">>, Resp).

-spec reason_text(livery_auth:error_reason()) -> binary().
reason_text(expired)             -> <<"token expired">>;
reason_text(not_yet_valid)       -> <<"token not yet valid">>;
reason_text(bad_signature)       -> <<"bad token signature">>;
reason_text(no_matching_key)     -> <<"no matching key">>;
reason_text(malformed)           -> <<"malformed token">>;
reason_text(invalid_json)        -> <<"malformed token">>;
reason_text(audience_mismatch)   -> <<"audience mismatch">>;
reason_text({issuer_mismatch, _}) -> <<"issuer mismatch">>;
reason_text({unsupported_alg, _}) -> <<"unsupported algorithm">>.
