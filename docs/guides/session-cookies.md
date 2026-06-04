# How to use signed session cookies

## Problem

You want to remember a little something about each user between
requests - who they are, what role they have - but you would rather
not stand up a session store, a database table, or a Redis to hold
it. The trick is to keep that state in the cookie itself, signed so
the client cannot forge it.

## Solution

That is exactly what `livery_auth_session` does. It signs a JSON
payload with HMAC-SHA256 and tucks it in a cookie. The payload rides
along with the client, and the signature is what stops anyone
tampering with it. Add the middleware with a shared `secret`:

```erlang
Stack = [
    {livery_auth_session, #{secret => Secret}}
    %% ... handler
].
```

On every request the middleware reads the cookie, verifies the
signature, and stashes the payload under `meta(session, _)`. Pull it
back out in a handler:

```erlang
fun(Req) ->
    case livery_ext:session(Req) of
        undefined           -> livery_resp:text(200, <<"hello, guest">>);
        #{<<"uid">> := Uid} -> livery_resp:text(200, [<<"hello #">>,
                                                      integer_to_binary(Uid)])
    end
end.
```

By default a missing cookie is waved through, so guests are fine.
Set `required => true` when you want to turn anonymous requests away
with `401`. Either way, a cookie that is present but tampered with or
expired is always rejected, no exceptions.

## Log in: set the cookie

When someone logs in, sign a payload (add `max_age` in seconds if
you want it to expire) and attach the `Set-Cookie` header to your
response:

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

- Use a long, random `secret`, and keep it out of source control.
- The payload is signed, not encrypted. Anyone can read it, so never
  put secrets in there.
- To rotate the secret, accept both the old and the new one for a
  while (verify against each), then drop the old one once the last
  cookies signed with it have aged out.

## See also

- Reference: `livery_auth_session`, `livery_ext`
- Recipe: [Extract a bearer token](bearer-tokens.md)
