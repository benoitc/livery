# How to add one-time codes as a second factor

`livery_auth_totp` checks the six-digit codes that authenticator apps
(Google Authenticator, 1Password, Authy, ...) show, following RFC 6238.
You need it when a password, or a sign-in with your identity provider,
is not enough for your users' accounts and you want a second factor they
already have on their phone.

## Enrol a user

Make a secret, show it as a QR code, and keep it only once the user has
typed a first code that works:

```erlang
Secret = livery_auth_totp:secret(),
Uri = livery_auth_totp:uri(Secret, #{
    issuer  => <<"Acme">>,
    account => <<"alice@example.org">>
}),
%% Render Uri as a QR code; also show livery_auth_totp:encode(Secret)
%% for people who type it in.
```

```erlang
confirm(User, Secret, Code) ->
    case livery_auth_totp:verify(Code, Secret, #{}) of
        {ok, Step} -> save_totp(User, Secret, Step);
        error -> {error, wrong_code}
    end.
```

Store the secret like a password hash: encrypted at rest, never logged,
never sent back to the browser after enrolment.

## Check a code at sign-in

Pass the step you stored last time, and store the one you get back:

```erlang
check(User, Code) ->
    #{secret := Secret, last_step := Last} = load_totp(User),
    case livery_auth_totp:verify(Code, Secret, #{last_step => Last}) of
        {ok, Step} -> save_last_step(User, Step), ok;
        error -> {error, wrong_code}
    end.
```

A code is accepted during its own 30 seconds and during one step before
and after, for phones whose clock drifts. `last_step` makes each code
work only once: a code someone saw over the user's shoulder is useless
once the user has signed in with it.

## Limit the attempts

A six-digit code has a million values; without a limit it can be
guessed. Rate limit the route per user:

```erlang
%% 5 attempts, then one more every 12 seconds, per signed-in user.
{livery_ratelimit, livery_ratelimit:limiter(5, 1 / 12, #{
    key => fun(Req) ->
        case livery_ext:session(Req) of
            #{<<"sub">> := Sub} -> Sub;
            _ -> undefined
        end
    end
})}
```

## Notes

- `algorithm` (`sha1`, `sha256`, `sha512`), `digits` (6 or 8) and
  `period` (seconds) can be changed, but most apps only support the
  defaults. Pass the same options to `uri/2` and `verify/3`.
- Give users recovery codes when they enrol, so a lost phone does not
  lock them out; Livery leaves that to your application.
- One-time codes stop a stolen password, not phishing: a fake sign-in
  page can ask for the code and use it within its 30 seconds. Passkeys
  (WebAuthn) resist that; see [Sign in with passkeys](sign-in-with-passkeys.md).

## See also

- Reference: `livery_auth_totp`, `livery_ratelimit`
- Guide: [Sign users in with OpenID Connect](sign-in-with-openid-connect.md)
