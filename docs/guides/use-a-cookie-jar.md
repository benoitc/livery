# How to use a cookie jar

The `cookie_jar` layer is the outbound twin of a browser's cookie store:
it keeps the cookies a response sets and sends the matching ones back on
later requests, so you never touch the `Cookie` header by hand. You need
it when the service you call uses cookies to carry state across requests,
a login that sets a session cookie, a CSRF token, an API that hands you a
cookie on the first call and expects it on the rest.

## Add a cookie jar

Put `cookie_jar()` in the stack and reuse the same client across the
calls that should share cookies. A response that sets a cookie fills the
jar; the next request through that client carries it.

```erlang
Client = livery_client:new(#{
    base_url => <<"https://api.example.com">>,
    stack    => [livery_client:cookie_jar()]
}),

%% Log in: the response sets a session cookie, the jar keeps it.
{ok, _} = livery_client:post(Client, <<"/login">>, json:encode(#{user => U, pass => P})),

%% Later calls through the same client send that cookie automatically.
{ok, Resp} = livery_client:get(Client, <<"/account">>),
200 = livery_client:status(Resp).
```

It stacks with the other layers like any of them, outermost-first:

```erlang
stack => [
    livery_client:timeout(5000),
    livery_client:retry(#{max => 3}),
    livery_client:cookie_jar()
]
```

## What the jar sends, and what it drops

The jar follows the client-side rules of RFC 6265, so it sends a stored
cookie only when it genuinely belongs on the request:

- host: a cookie set without a `Domain` is sent back only to the exact
  host that set it; a `Domain` cookie also reaches its sub-domains.
- path: a cookie scoped to `/admin` goes to `/admin` and below, not to
  `/`.
- secure: a `Secure` cookie is sent over `https` only, never plain
  `http`.

When several cookies match, they are ordered longest-path-first in the
one `Cookie` header. A `Cookie` header you set yourself is kept, the jar
appends to it rather than clobbering it. Cookies expire on their own:
a `Max-Age` of `0` or a past `Expires` deletes the cookie, and expired
ones are dropped before each send.

## Tune the jar

`cookie_jar/1` takes options:

```erlang
livery_client:cookie_jar(#{max_cookies => 500}).
```

- `max_cookies` caps how many cookies the jar holds (default 3000); past
  the cap the oldest are evicted.
- `store` names the backing store module (default
  `livery_client_cookie_store_ets`); see below.

## Build the client where it will live

The default store is a public ETS table created by the constructor and
owned by the process that calls it. That table lives as long as its
owner, so build the client in a process that outlives the requests, your
supervision tree, a long-lived worker, an application's setup, not a
short-lived request process that takes the jar down with it when it
exits. Once built, the client value is safe to share: the table is
public, so any number of processes can issue requests through the same
jar at once.

## Back the jar with something else

The jar keeps no cookies of its own. It reads and writes through the
`livery_client_cookie_store` behaviour, four callbacks over an opaque
handle:

```erlang
-callback init(Opts :: map()) -> store().
-callback get(store()) -> [cookie()].
-callback put(store(), key(), cookie()) -> ok.
-callback delete(store(), key()) -> ok.
```

The default is the per-jar ETS table. To survive the building process,
share one store across clients, or push cookies into an external cache,
implement the behaviour over a supervised process and name it:

```erlang
livery_client:cookie_jar(#{store => my_cookie_store}).
```

Cookies and keys are opaque to the store, it persists and returns them
without looking inside, so a custom store is only the four callbacks.

## What it does not do

This is a deliberate subset for talking to services: no public suffix
list, no third-party-cookie policy, no persistence to disk. `SameSite`
is parsed but not enforced. For browser-grade behaviour you would layer
those on top.

## See also

- Guide: [Make outbound HTTP requests](make-http-requests.md)
- Guide: [Use signed session cookies](session-cookies.md) (the server side)
- Reference: `livery_client`, `livery_client_cookie`, `livery_client_cookie_store`
