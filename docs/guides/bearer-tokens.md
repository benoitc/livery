# How to extract a bearer token

`livery_ext:bearer_token/1` reads the bearer token from the
`Authorization` header. You need it when a handler or auth middleware
has to pull the token out before verifying it.

## Read the token

```erlang
case livery_ext:bearer_token(Req) of
    undefined -> livery_resp:text(401, <<"missing token">>);
    Token     -> use_token(Token)
end.
```

`livery_ext:bearer_token/1`:

- Reads the `Authorization` header (case-insensitive).
- Accepts the `Bearer` scheme in any case (`Bearer`, `bearer`,
  `bEaReR`), as RFC 9110 section 11.1 says.
- Returns the token after the scheme, or `undefined` when the header
  is absent, uses another scheme, or has an empty token.

## Use it inside a middleware

```erlang
-module(my_auth).
-behaviour(livery_middleware).
-export([call/3]).

call(Req, Next, _State) ->
    case livery_ext:bearer_token(Req) of
        undefined ->
            livery_resp:text(401, <<"missing token">>);
        Token ->
            case verify(Token) of
                {ok, User} -> Next(livery_req:set_meta(user, User, Req));
                error      -> livery_resp:text(401, <<"bad token">>)
            end
    end.

%% Replace with real verification; livery_auth does JWT/JWKS for you.
verify(_Token) -> {ok, #{}}.
```

Place it in the stack after `livery_request_id` and
`livery_access_log` so the audit log records the failed attempt.

## Handle non-bearer schemes

`livery_ext:bearer_token/1` only matches the bearer scheme. For Basic
auth, read the header yourself and decode it:

```erlang
case livery_req:header(<<"authorization">>, Req) of
    <<"Basic ", B64/binary>> -> base64:decode(B64);
    _ -> undefined
end.
```

## Notes

- To verify JWT access tokens, use `livery_auth_bearer` instead of
  writing your own; see [Verify JWT access tokens](verify-access-tokens.md).

## See also

- Reference: `livery_ext`
- Guide: [Write a custom middleware](custom-middleware.md)
