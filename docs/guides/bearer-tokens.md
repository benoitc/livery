# How to extract a bearer token

## Problem

Your handler or auth middleware needs the bearer token from the
`Authorization` header.

## Solution

```erlang
case livery_ext:bearer_token(Req) of
    undefined -> livery_resp:text(401, <<"missing token">>);
    Token     -> use_token(Token)
end.
```

`livery_ext:bearer_token/1`:

- Reads the `Authorization` header (case-insensitive).
- Accepts `Bearer `, `bearer `, and `BEARER ` prefixes (RFC 6750
  §2.1 makes the scheme case-insensitive).
- Returns the token bytes after the prefix, or `undefined` when the
  header is absent or uses another scheme.

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
```

Place it in the stack after `livery_request_id` and
`livery_access_log` so the audit log records the failed attempt.

## Non-bearer schemes

`livery_ext:bearer_token/1` only matches the bearer scheme. For
Basic auth, read the header directly and decode:

```erlang
case livery_req:header(<<"authorization">>, Req) of
    <<"Basic ", B64/binary>> -> base64:decode(B64);
    _ -> undefined
end.
```

OIDC, JWKS rotation, and JWT verification ship as `livery_auth` in
Phase 8.

## See also

- Reference: `livery_ext`
- Recipe: [Write a custom middleware](custom-middleware.md)
