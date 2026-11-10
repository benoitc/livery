# How to sign in with passkeys

`livery_auth_passkey` lets people sign in with a passkey: the
fingerprint, face or PIN prompt of their phone, laptop or security key,
instead of a password. You need it when you want a sign-in that phishing
cannot defeat: the browser only uses a passkey on the site it was made
for, so a look-alike page gets nothing it can replay. It also works as a
second factor after a password or an OpenID Connect sign-in.

## Add the routes

Your application keeps the passkeys; Livery calls you to read and write
them. Here with an ETS table to keep the example short:

```erlang
Passkeys = #{
    rp_id   => <<"app.example">>,
    rp_name => <<"Example">>,
    origins => [<<"https://app.example">>],
    session => #{secret => SessionSecret, max_age => 8 * 3600},

    current_user => fun(Req) ->
        case livery_ext:session(Req) of
            #{<<"uid">> := Id} -> #{id => Id, name => user_name(Id)};
            _ -> undefined
        end
    end,
    credentials_for_user => fun(#{id := Id}) ->
        [CredId || {CredId, Owner, _} <- ets:tab2list(passkeys), Owner =:= Id]
    end,
    store_credential => fun(#{id := Id}, #{id := CredId} = Cred) ->
        case ets:insert_new(passkeys, {CredId, Id, Cred}) of
            true -> ok;
            false -> {error, exists}
        end
    end,
    find_credential => fun(CredId) ->
        case ets:lookup(passkeys, CredId) of
            [{_, Owner, Cred}] -> {ok, #{id => Owner, name => user_name(Owner)}, Cred};
            [] -> not_found
        end
    end,
    update_credential => fun(CredId, Updates) ->
        [{_, Owner, Cred}] = ets:lookup(passkeys, CredId),
        true = ets:insert(passkeys, {CredId, Owner, maps:merge(Cred, Updates)}),
        ok
    end,
    on_login => fun(#{id := Id}, _Cred) -> #{<<"uid">> => Id} end
},
Router = livery_router:compile(livery_auth_passkey:routes(Passkeys) ++ AppRoutes).
```

This adds four POST routes under `/passkeys`: `register/options` and
`register` for a signed-in user to add a passkey, `login/options` and
`login` to sign in with one. The user `id` is a stable opaque handle (a
database id, not an email), at most 64 bytes. Store the whole credential
map you are given; it holds the public key and counter Livery needs
later. `store_credential` must refuse an `id` that is already stored,
for any user, in the same step as the insert, and return
`{error, exists}`: a passkey belongs to one account only.

## Call them from the page

The browser does the cryptography. Modern browsers turn the JSON options
into what `navigator.credentials` wants, and back:

```javascript
async function addPasskey() {
  const options = await post("/passkeys/register/options");
  const credential = await navigator.credentials.create({
    publicKey: PublicKeyCredential.parseCreationOptionsFromJSON(options),
  });
  await post("/passkeys/register", credential.toJSON());
}

async function signIn() {
  const options = await post("/passkeys/login/options");
  const credential = await navigator.credentials.get({
    publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(options),
  });
  await post("/passkeys/login", credential.toJSON());
  location.href = "/";
}

async function post(path, body = {}) {
  const r = await fetch(path, {
    method: "POST",
    credentials: "same-origin",
    headers: {"content-type": "application/json"},
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error((await r.json()).error);
  return r.json();
}
```

Sign-in needs no username: the browser offers the passkeys it holds for
your site. A successful sign-in sets the session cookie, which
`livery_auth_session` reads on the next requests.

## What is checked for you

- The origin and the RP ID, so a passkey made for your site is useless
  anywhere else.
- A fresh challenge for every ceremony, kept in a signed two-minute
  cookie and accepted once.
- That the user was present, and verified (fingerprint, face, PIN) when
  you set `user_verification => required`.
- The signature, with the key stored at registration, and the counter,
  which refuses a cloned security key.
- On registration, the attestation: `none` (what synced passkeys send)
  or `packed`. Set `attestation_roots` to the CA certificates of the
  security keys you accept to require a verified `packed` chain; any
  other passkey is then refused, unless you also set
  `allow_unattested => true`.
- That a credential id is registered once, to one user.

## Notes

- Keep `rp_id` your registrable domain (`app.example`), and list every
  origin that serves the page in `origins`. A passkey made under one RP
  ID does not work under another.
- Passkeys synced between devices (Apple, Google, password managers)
  always report a counter of 0; that is expected.
- Each challenge is accepted once per node. In a cluster, pass
  `challenge_replay => fun((Key, ExpiresAt) -> fresh | replayed)` backed
  by a shared store.
- For a second factor, the routes are not the right tool: they sign in
  whoever owns the passkey. After the first sign-in, call
  `livery_auth_webauthn:request_options/1` with `allow` set to that
  user's credential ids, and `verify_authentication/3` with the stored
  credential and `user_identified => true`; refuse any other passkey.
- A page on another site that frames yours needs
  `allow_cross_origin => true` and its origin in `top_origins`.
- To check passkeys yourself, without the routes, use
  `livery_auth_webauthn:creation_options/2`, `verify_registration/2`,
  `request_options/1` and `verify_authentication/3`.

## See also

- Reference: `livery_auth_passkey`, `livery_auth_webauthn`, `livery_auth_session`
- Guide: [Add one-time codes as a second factor](add-totp.md)
- Guide: [Sign users in with OpenID Connect](sign-in-with-openid-connect.md)
