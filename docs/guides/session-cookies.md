# How to use signed session cookies

## Problem

You want to keep a small amount of per-user state (a user id, a
role) across requests without a server-side session store.

## Solution

`livery_auth_session` signs a JSON payload with HMAC-SHA256 and
stores it in a cookie. The payload travels with the client; the
signature stops it being tampered with. Add the middleware with a
shared `secret`:

```erlang
Stack = [
    {livery_auth_session, #{secret => Secret}}
    %% ... handler
].
```

On each request the middleware reads the cookie, verifies it, and
stores the payload under `meta(session, _)`. Read it in a handler:

```erlang
fun(Req) ->
    case livery_ext:session(Req) of
        undefined           -> livery_resp:text(200, <<"hello, guest">>);
        #{<<"uid">> := Uid} -> livery_resp:text(200, [<<"hello #">>,
                                                      integer_to_binary(Uid)])
    end
end.
```

A missing cookie is allowed through by default. Set
`required => true` to reject anonymous requests with `401`. A
present but tampered or expired cookie is always rejected.

## Log in: set the cookie

Sign a payload (optionally with `max_age` seconds for expiry) and
attach the `Set-Cookie` header to your response:

```erlang
login(_Req) ->
    Opts  = #{secret => Secret, max_age => 3600},
    Value = livery_auth_session:sign(#{<<"uid">> => 42}, Opts),
    {K, V} = livery_auth_session:set_cookie_header(Value, Opts),
    R = livery_resp:redirect(303, <<"/">>),
    livery_resp:with_header(K, V, R).
```

`set_cookie_header/2` defaults to `Path=/; SameSite=Lax; Secure;
HttpOnly`. Override with `path`, `domain`, `secure`, `http_only`,
and `same_site`.

## Log out: clear the cookie

```erlang
logout(_Req) ->
    {K, V} = livery_auth_session:clear_cookie_header(#{}),
    R = livery_resp:redirect(303, <<"/">>),
    livery_resp:with_header(K, V, R).
```

## Notes

- Use a long, random `secret` and keep it out of source control.
- The payload is signed, not encrypted: do not store secrets in it.
- Rotate the secret by accepting both old and new during a window
  (verify against each), then drop the old one.

## See also

- Reference: `livery_auth_session`, `livery_ext`
- Recipe: [Extract a bearer token](bearer-tokens.md)
