# How to use signed session cookies

`livery_auth_session` signs a JSON payload with HMAC-SHA256 and
stores it in a cookie. You need it when you want to keep a small
amount of per-user state (a user id, a role) across requests
without a server-side session store. The payload travels with the
client; the signature stops anyone from changing it.

## Add it to the stack

Add the middleware with a shared `secret`:

```erlang
Stack = [
    {livery_auth_session, #{secret => Secret}}
    %% ... handler
].
```

On each request the middleware reads the cookie, verifies it, and
stores the payload under `meta(session, _)`. Read it in a handler
with `livery_ext:session/1`:

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
cookie that is present but was tampered with or has expired is always
rejected.

## Log in: set the cookie

Sign a payload (add `max_age`, in seconds, if it should expire) and
add the `Set-Cookie` header to your response:

```erlang
login(_Req) ->
    Opts  = #{secret => Secret, max_age => 3600},
    Value = livery_auth_session:sign(#{<<"uid">> => 42}, Opts),
    {K, V} = livery_auth_session:set_cookie_header(Value, Opts),
    R = livery_resp:redirect(303, <<"/">>),
    livery_resp:with_header(K, V, R).
```

`set_cookie_header/2` defaults to `Path=/; SameSite=Lax; Secure;
HttpOnly`. Change them with `path`, `domain`, `secure`, `http_only`,
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
- The middleware checks a single `secret`. To rotate it, accept both
  the old and the new one for a while in your own middleware, in place
  of `livery_auth_session`, calling `livery_auth_session:verify/2` with
  each, then drop the old one.

## See also

- Reference: `livery_auth_session`, `livery_ext`
- Guide: [Extract a bearer token](bearer-tokens.md)
