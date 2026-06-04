# How to extract a bearer token

## Problem

A client sends you a token in the `Authorization` header, and you
need to pull it out cleanly before you can verify it. The header has
a scheme prefix, the casing varies between clients, and you would
rather not parse it by hand in every handler.

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

%% Replace with real verification; livery_auth does JWT/JWKS for you.
verify(_Token) -> {ok, #{}}.
```

Put it in the stack after `livery_request_id` and
`livery_access_log`, so a failed attempt still lands in your audit
log.

## Non-bearer schemes

`livery_ext:bearer_token/1` only matches the bearer scheme. If you
need Basic auth instead, read the header yourself and decode it:

```erlang
case livery_req:header(<<"authorization">>, Req) of
    <<"Basic ", B64/binary>> -> base64:decode(B64);
    _ -> undefined
end.
```

And when you need the real machinery - OIDC, JWKS rotation, JWT
verification - it all ships as `livery_auth`.

## See also

- Reference: `livery_ext`
- Recipe: [Write a custom middleware](custom-middleware.md)
