# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `livery_a2a:router/2` takes `max_body_bytes` and `body_timeout_ms`, the
  same request body limits `livery_mcp` already has.

### Changed

- An adapter written outside Livery can now offer WebSocket and
  WebTransport: `livery_ws:upgrade/3` and `livery_wt:upgrade/3` use any
  adapter that implements `accept_ws/4` or `accept_wt/4`, now optional
  callbacks of `livery_adapter`, instead of a fixed list of Livery's own
  adapters. `accept_wt/4` takes the stream as its first argument, like
  `accept_ws/4`.
- An HTTP/2 or HTTP/3 request now runs in one process fewer: the adapter
  works in the process the wire library already starts for the request,
  as HTTP/1.1 does.

### Deprecated

- `livery_resp:upgrade/2`. No adapter ever acted on the response it
  builds; use `livery_ws:upgrade/3` or `livery_wt:upgrade/3`.
- `livery_body:signal_demand/2`. Reading the body with
  `livery_body:read/2` now gives flow-control credit back by itself.

### Fixed

- An A2A request whose body was too large, too slow or cut off reached
  the agent as an empty request, so the client got a JSON parse error
  instead of the real reason. It is now refused before the agent sees
  it: `413` when the body is over the limit, including the listener's
  `max_body`, which A2A did not respect, `408` when it stalls, `400` when
  it ends early. MCP already behaved this way, and both now share the
  same code. A2A now waits up to 60 seconds for each body chunk, as MCP
  does, instead of 30.
- A compressed response kept the strong `ETag` of the uncompressed one,
  so the gzip and the plain representation claimed to be the same bytes
  (RFC 9110 section 8.8.1). Caches and clients that compare ETags
  strictly could mix them up. `livery_compress` now makes that ETag weak
  (`W/"v1"`); revalidation with `If-None-Match` keeps working.
- A handler that read its request body slowly, or not at all, let the
  whole body pile up in memory, up to `max_body`, although the docs
  promised flow control. On HTTP/2 and HTTP/3 the client can now send
  only one flow window ahead of what the handler has read; a body the
  handler does not read to the end is stopped once the response is sent
  (RFC 9113 section 8.1, RFC 9114 section 4.1.1). HTTP/1.1 still relies
  on TCP buffers alone, until `erlang_h1` offers receive flow control.
- Over HTTP/2, a WebSocket message larger than about 1 MiB could not be
  sent while the client's flow window was small, and never reached the
  client. The server now waits for the window, up to 30 seconds, as it
  already did over HTTP/3.
- An HTTP/3 request cancelled by the client right after its headers
  still started its handler, which then waited for a body that would
  never come and held its place in the request limit until it gave up.
  Such a request is now dropped before the handler starts.
- A `livery_concurrency` slot taken behind `livery_timeout` was never
  given back when the deadline cut the request off, so after enough
  timeouts every request was refused with 503. Even without a timeout,
  the slot was given back before the response was sent instead of
  after.
- Behind `livery_timeout`, a handler could not read a streamed request
  body, did not receive the disconnect notice, and lost the logger
  metadata and trace context set before it. The deadline now runs the
  handler with all of them.

## [0.12.1] - 2026-11-11

Moves the MCP and A2A support to barrel_mcp 4.5.0 and barrel_a2a 0.3.0,
both security releases. Nothing changes in Livery itself.

### Changed

- Livery is tested against barrel_mcp 4.5.0 and barrel_a2a 0.3.0, and
  the MCP and A2A guides now ask for them. Both are security releases
  (requests steered to private addresses, cleartext credentials,
  webhook secrets stored in clear); if you serve MCP or A2A, upgrade
  the one you list in your own dependencies.

## [0.12.0] - 2026-11-10

Security release (GHSA-r4pj-gcrj-m4fv), with passkeys and DPoP for the
OAuth client. Before upgrading, check: the Prometheus names of the HTTP
server metrics change with instrument 2.0, and a sign-in in progress
during the upgrade has to start again.

### Security

- The cookie that carries an OpenID Connect sign-in in progress was
  signed with the session secret, and `livery_auth_session` accepted it
  as a session (GHSA-r4pj-gcrj-m4fv). Each kind of signed cookie now
  has its own key derived from the secret, so a cookie made for one use
  is refused for any other. Existing session cookies stay valid; a
  sign-in started before the upgrade has to start again.

### Added

- Passkeys (WebAuthn Level 3). `livery_auth_passkey` gives the routes to
  register a passkey and to sign in with one, without a username,
  ending in a session cookie; your application keeps the credentials
  through callbacks. `livery_auth_webauthn` has the checks on their own:
  origin, RP ID, challenge (used once), user presence and verification,
  backup flags, signature and counter, and `none` or `packed`
  attestation. Passkeys resist phishing, which one-time codes do not.
- The OAuth client layer can bind its tokens to a key with DPoP (RFC
  9449), so a token copied from a log or a proxy cannot be used by
  anyone else. With `dpop => true`, the token request and every API
  request carry a proof signed by that key, and a server's request for
  a nonce is followed. Before, an authorization server issuing DPoP
  tokens could not be used at all.

### Changed

- The Prometheus names of the HTTP server metrics changed with
  instrument 2.0: the request attributes (method, status, protocol,
  scheme) are now labels of one metric, `http_server_request_duration`
  and `http_server_active_requests`, instead of being folded into the
  metric name. Update dashboards and alerts that use the old names. A
  metric now appears after its first request rather than as a zero.
- Dependencies: h2 0.15.1 (a closed connection is noticed at once
  instead of after five seconds), hackney 4.10.2 (pooled connections no
  longer hang on close or leak per-host slots), webtransport 0.5.5 and
  instrument 2.0.0.

## [0.11.0] - 2026-11-10

Auth release: Livery becomes a complete OAuth resource server, OAuth
client and OpenID Connect relying party (bound tokens, step-up, PAR,
TOTP), and fixes a review's worth of spec and limit bugs. Before
upgrading, check: refused requests now carry RFC 6750 error codes and a
missing scope is `403`; key sets with mislabelled keys or short RSA keys
are no longer used; a `verify_peer` listener with conflicting
`ssl_opts` no longer starts; `livery_body_limit` and the client's q-values
in `Accept-Encoding` now take effect.

### Added

- `livery_auth_totp` checks the one-time codes of authenticator apps
  (RFC 6238), for a second sign-in factor. It builds the QR code URI,
  allows for clock drift and accepts each code only once; the guide
  shows how to enrol users and rate limit attempts.
- Routes can require a stronger or more recent sign-in with
  `acr_values` and `max_age` (RFC 9470). A token that falls short gets
  `401` with `error="insufficient_user_authentication"`, and
  `livery_auth_login` can send the user back through sign-in with the
  level asked for, then checks that the provider delivered it.
- `livery_auth_login` sends the login request to the provider directly
  when it supports pushed authorization requests (RFC 9126), so it no
  longer travels in the browser's URL. `livery_auth_token:push_request/3`
  does it on its own.
- `livery_client:oauth/1` adds an OAuth client-credentials token to
  outbound requests. Tokens are cached until shortly before they expire,
  a burst of requests shares one new token, and a revoked token is
  replaced once. Clients can authenticate with a secret, a signed
  assertion (RFC 7523 as updated by RFC 10070) or mutual TLS. The token
  is sent only to the origins it is meant for (`allowed_origins`, or
  the `resource`), checked just before the request leaves.
- `livery_auth_login` signs users in with OpenID Connect: authorization
  code with PKCE, `state` and `nonce`, the RFC 9207 issuer check and full
  ID token validation, ending in a signed session cookie.
- `livery_auth_token:request/3` makes token requests directly.
- DPoP resource servers can require a server nonce in every proof
  (`dpop_nonce`), so proofs cannot be made in advance. Nonces are
  stateless and shared by every node with the same secret.
- Logging out with `livery_auth_login` also signs the user out of the
  provider when it supports OpenID Connect RP-Initiated Logout.
- Sender-constrained access tokens. A token bound to a client
  certificate (RFC 8705) or to a DPoP key (RFC 9449) is now accepted
  only from that client, and `dpop => true` lets clients send DPoP
  proofs. `binding` refuses tokens that are not bound at all.
- `livery_auth_resource` publishes OAuth protected resource metadata
  (RFC 9728), and the `resource_metadata` option points refused clients
  at it.
- JWT access tokens signed with RS384, RS512, PS256, PS384, PS512,
  ES384, ES512, Ed25519 or Ed448 are now accepted, along with RS256 and
  ES256. You can narrow the list with `algorithms`.
- `livery_auth_bearer` and `livery_auth:verify/2` can require scopes
  (`scope`), a token type (`typ`), given claims (`required_claims`) or
  the whole RFC 9068 access token profile (`profile => access_token`).
- `livery_auth_introspect` can check the token's audience and scopes.
- `livery_auth_oidc:discover_oauth/1,2` reads an OAuth authorization
  server's metadata (RFC 8414), for issuers without OpenID Connect.
- A guide on verifying JWT access tokens, and a list in AGENTS.md of
  the places where Livery knowingly differs from a specification, with
  the reason for each.

### Changed

- A token carrying `cnf.jkt` is refused when sent as `Bearer`, and one
  carrying `cnf.x5t#S256` is refused without the matching client
  certificate. Before, both were accepted like any bearer token.
- Refused requests now tell the client why, as RFC 6750 asks: a bad
  token gets `error="invalid_token"` in `WWW-Authenticate`, and a token
  without a required scope gets `403` with `error="insufficient_scope"`
  instead of `401`. A `realm` option names your API in the challenge.
- A token naming a key the cached set does not have now fetches the set
  again at most once every 30 seconds (`min_refresh_interval`). Before,
  every such request fetched it, so made-up key ids could flood the
  issuer.
- A key is used only when its type, curve, `alg`, `use` and `key_ops`
  agree with the token, and RSA keys under 2048 bits are refused. A key
  set that mislabels its keys may need fixing.

### Fixed

- `livery_body_limit` only checked bodies that were already buffered,
  which the adapters never produce, so its limit did not apply. A
  `Content-Length` above it now gets `413` before the handler runs, and
  a streamed body is read through a reader that refuses to go past it.
- `livery_concurrency` released its slot as soon as the handler
  returned, so streamed responses such as SSE stopped counting while
  they were still being sent. The slot is now held until the response
  has been sent.
- Multipart parsing was looser than RFC 2046: it took any boundary,
  found delimiters in the middle of a line, treated text that merely
  started like a delimiter as one, and broke quoted parameters such as
  a `filename` holding `;` or `\"`. Boundaries are now checked, a
  delimiter must start a line and end correctly, and quoted values are
  read properly.
- Compression now follows the client's preferences: the coding with the
  highest `Accept-Encoding` q-value wins, where before the server's
  order did. A client that refuses unencoded content and accepts none of
  the available codings gets `406` instead of an unencoded body
  (RFC 9110 section 12.5.3). Malformed q-values are ignored.
- A range that starts at the end of a file, or any range on an empty
  file, was answered with an empty `206`. It now gets `416`, and every
  `416` says how long the file is with `Content-Range: bytes */<size>`
  (RFC 9110 sections 14.1.2 and 14.4).
- Static files ignored `If-Range`, so a client resuming a download of a
  file that had changed could get a mix of old and new bytes. A range is
  now served only when the `If-Range` date matches, and static responses
  carry `Last-Modified` (RFC 9110 section 13.1.5).
- Server-sent events with several lines of `data` were sent as one
  broken field, and a line break in `event`, `id` or `retry` could
  start a new field or event. Every line now gets its own `data:`, and
  the other fields are kept to one line.
- A listener with `verify => verify_peer` could have client
  certificates turned off, or its trusted CAs replaced, by a matching
  key in `ssl_opts` or `quic_opts`, without any warning. It now refuses
  to start and names the conflicting keys. HTTP/2 listeners also
  require the client certificate explicitly.
- A JWT or session cookie was still accepted at the exact second it
  expired. It now expires at `exp`, as RFC 7519 section 4.1.4 says.
- HTTP/1.1 requests reported their scheme as `http` and an empty
  authority, even over TLS. They now carry `https` on a TLS listener and
  the authority from `Host`, as HTTP/2 and HTTP/3 already did.
- A token with a `crit` header was accepted although Livery understands
  none of the extensions it may name. It is now refused (RFC 7515
  section 4.1.11).
- An `exp` or `nbf` with a fractional part was read as expired. Any
  number is now accepted, and a value that is not a number is reported
  as an invalid claim instead of as expired.
- Introspection sent `client_id` and `client_secret` to the Basic header
  without form-encoding them, so a secret with `:` or `+` could fail
  (RFC 6749 section 2.3.1).

## [0.10.8] - 2026-11-09

Security release (GHSA-q86r-w492-w8c2), with mutual TLS on every listener
and h1 0.10.0, h2 0.15.0, quic 2.6.1, webtransport 0.5.3 and hackney
4.10.0. Erlang/OTP 27 or later is required, as before.

### Added

- Mutual TLS on every listener. With `verify => verify_peer` and
  `cacerts`, HTTP/1.1, HTTP/2 and HTTP/3 listeners refuse clients
  without a certificate signed by your CAs, and `livery_req:tls/1` now
  returns the verified certificate with its subject and alternative
  names, so you can map a client to an identity. HTTP/3 listeners
  accept `verify` for the first time. Over TLS without client
  certificates the request reads `#{verified => false}` instead of an
  empty map.

### Security

- `livery_static` could serve files outside its root through a symbolic
  link to a directory inside it. Every part of the path below the root is
  now checked, and a link anywhere in it is answered with 404.
- The client cookie jar stored a cookie for any domain a response named,
  and sent it to that domain later. A cookie is now kept only for a
  domain the responding host belongs to (RFC 6265 section 5.3), and a
  single-label domain such as `com` is refused.
- `livery_auth_oidc:discover/1,2` accepted a discovery document naming a
  different issuer, or none, so an application could take another
  provider's keys and issuer for its own. The issuer must now match the
  one requested exactly (OpenID Connect Discovery 1.0 section 4.3).
- HTTP/2 servers now close connections that abuse stream resets
  (MadeYouReset, CVE-2025-8671) or flood SETTINGS frames
  (CVE-2019-9515). Either let one client tie up the server.
- An HTTP/3 request with a large header block could keep a CPU busy for
  minutes. Header blocks now decode in linear time and stop at the size
  limit, trailers included.
- The hackney client no longer buffers an unlimited amount of data past
  `max_body_size` when a server sends one huge chunk.

### Changed

- WebTransport moves to the current drafts: draft-17 over HTTP/3 and
  draft-16 over HTTP/2. Chrome, Firefox and Safari 26 still connect
  over HTTP/3. Over HTTP/2 a session now needs TLS 1.3, and peers still
  on draft-14 no longer interoperate.
- The client now waits for a free stream when an HTTP/2 or HTTP/3
  server is at its concurrent stream limit, instead of failing, and
  sends a request the server refused without processing once more on a
  fresh connection.

### Fixed

- Starting an HTTP/3 listener created a new atom every time, even when
  you gave it a `name`. Atoms are never freed, so a service that kept
  restarting listeners slowly filled the atom table. A named listener
  now creates none.
- A bearer token whose header or claims are valid JSON but not an
  object crashed verification, so the request got a 500. It is now
  rejected as an invalid token.
- HTTP/3 requests reported their scheme as `http` and an empty
  authority. webtransport 0.5 refuses such a session with 400, the
  security headers middleware never sent HSTS over HTTP/3, and traces
  recorded the wrong scheme and server address. They now carry the
  scheme and authority the client sent.
- The HTTP/3 listener now passes on the options `webtransport:h3_settings/0`
  sets: requests wait for the client's settings, resets report their
  final size for flow control, and a WebTransport handler that could not
  open a stream because the peer allowed no more is told when it can try
  again.
- Data a client sends right after a CONNECT tunnel or an Upgrade is
  accepted over HTTP/1.1 is no longer lost.
- Large HTTP/3 downloads no longer stop part way with a flow-control
  error, and transfers on paths that reorder packets are several times
  faster.

## [0.10.7] - 2026-10-26

Dependency release: hackney 4.9.0 and h2 0.12.5.

### Changed

- The hackney client now uses hackney 4.9.0, which closes several
  security holes: private addresses hidden in some URL spellings were
  still reachable, a pinned CA did not limit which servers were trusted,
  credentials were resent on some cross-origin redirects, and a server
  could exhaust memory with an endless or highly compressed body.
- h2 is now 0.12.5, which adds the `connection_window_size` option for
  faster large transfers over slow links. Nothing changes unless you set
  it.

## [0.10.6] - 2026-10-25

Request body fixes for HTTP/2 and HTTP/3, with quic 2.1.2.

### Fixed

- Uploads over HTTP/2 and HTTP/3 that exceed the size limit now get a
  413 response instead of a stream error. Once the response is sent,
  the client is told to stop sending the rest of the body.
- Requests without a body no longer hang over HTTP/3 when the handler
  reads the body. This comes with quic 2.1.2, which also stops an early
  413 from being lost on a lossy link.

## [0.10.5] - 2026-10-04

WebTransport release: the client protocol passed through on HTTP/3,
with webtransport 0.4.8, hackney 4.8.5, h2 0.12.4 and quic 2.1.1.

### Fixed

- `livery_wt:upgrade/3` over HTTP/3 now hands the `webtransport` library
  the `:protocol` value the client sent. The adapter rebuilt the pseudo
  headers with the draft-02 spelling `webtransport`, so every session was
  negotiated in legacy mode even for draft-15 clients that said
  `webtransport-h3`. Pseudo headers the adapter kept in the request's
  header list are dropped before the rebuilt ones are added, so none
  appears twice.

### Added

- `livery_wt_SUITE` checks the protocol passthrough and starts one
  service with the WebTransport settings merged into both the `http3`
  and the `https` listener, echoing 1 MiB over each transport.

### Changed

- Bump `webtransport` 0.4.7 -> 0.4.8, `hackney` 4.8.4 -> 4.8.5, `h2`
  0.12.3 -> 0.12.4 and `quic` 2.0.3 -> 2.1.1. h2 and quic keep the
  streams already open working after a GOAWAY, sent or received, and
  hackney fails only the requests the server refused. webtransport no
  longer truncates payloads larger than one HTTP/2 DATA frame or loses
  bytes past the per-stream window. Nothing changes in livery's own
  code.

## [0.10.4] - 2026-10-02

MCP release: barrel_mcp 4.3.0, and the body and keepalive options of
its own listener on `livery_mcp`.

### Added

- `livery_mcp` options `max_body_bytes` (default 16 MiB, answered
  `413`), `body_timeout_ms` (default 60000, answered `408`) and
  `sse_keepalive_ms` (falls back to the `barrel_mcp` app env). A body
  that failed to read used to reach the engine as an empty body.

### Changed

- `barrel_mcp` `~> 4.3.0` in the `test` and `check` profiles. The MCP
  guide covers `instructions`, `visible/4`, `authorize_subscribe/3`
  and durable or application-hosted tasks, which work through livery
  unchanged.
- The per-chunk MCP body wait moves from 30s to 60s, as in barrel_mcp.

## [0.10.3] - 2026-09-27

Dependency release: quic 2.0.3 and hackney 4.8.4, with the HTTP/3 fixes
they call for.

### Changed

- Bump `quic` 1.8.2 -> 2.0.3, `webtransport` 0.4.5 -> 0.4.7, `h2`
  0.12.0 -> 0.12.3 and `hackney` 4.7.4 -> 4.8.4. hackney 4.8 is what
  pulls quic 2.0 in. For livery's own code nothing changes; if your
  handlers talk to `quic_h3` directly, a connection close now always
  arrives as `{quic_h3, Conn, {closed, Reason}}`.
- The outbound client reports a response body cut short by the server
  closing as `{error, {closed, Partial}}` (buffered) or `{error, closed}`
  (streamed), where it used to return the short body as a success.
- Test and check profiles: `barrel_mcp` 4.1.1, `barrel_a2a` 0.2.3.

### Fixed

- On HTTP/3, a request body over `max_body` no longer fires the
  handler's `on_disconnect` callbacks. quic 2.0 reports the reset livery
  sends back to the stream, and the translator took it for a client
  disconnect.
- On HTTP/3, a response sent faster than the connection drains is no
  longer cut. quic refuses a send while its connection send queue is
  full (`{error, send_queue_full}`, nothing written); livery passed that
  up, so a streamed body silently lost the refused chunk and a full body
  left the stream open. The adapter now waits for the queue to drain,
  sending bodies in 64 KiB pieces, and resets the stream if it is still
  full after 30 seconds (`{error, send_timeout}`). WebSocket sends over
  HTTP/3 wait the same way.
- A response that fails part way (any emit error other than a closed
  peer) now resets the stream instead of leaving it open.
- `on_disconnect` callbacks no longer run when livery resets the stream
  itself, for example when a file response cannot be read. HTTP/1.1
  always ran them and HTTP/3 sometimes did; HTTP/2 never did.

## [0.10.2] - 2026-09-21

### Changed

- `barrel_mcp` and `barrel_a2a` are no longer top-level dependencies.
  They were optional at runtime since 0.10.0 but still fetched and
  locked by every project depending on livery. An application that uses
  `livery_mcp` or `livery_a2a` adds the library to its own `deps`. The
  `test` profile pulls them for the suites, and xref and dialyzer run
  under the new `check` profile (`rebar3 as check xref`).

## [0.10.1] - 2026-09-21

Dependency release: `barrel_mcp` 4.0.0, whose bearer provider no longer
accepts `audience => any` without a `verifier`.

### Changed

- Bump `barrel_mcp` 3.0.1 -> 4.0.0. One thing to check if you pass
  `barrel_mcp_auth_bearer` to `livery_mcp` with `audience => any`: without
  a `verifier` fun the provider now refuses to start, and the handler
  fails at construction with
  `{auth_provider, _, audience_any_requires_verifier}`. Name the resource
  as the audience instead.
- Bump test and bench dependencies: `cowboy` to 2.19.0, `cowlib` to
  2.20.0, `ranch` to 2.3.0.
- Bump tooling: `rebar3_lint` to 6.0.0 (elvis_core 6.0.0).

## [0.10.0] - 2026-09-20

### Added

- `livery_a2a`: serve an A2A agent (agent card, JSON-RPC and HTTP+JSON
  bindings, SSE streams) from a Livery service. `livery_a2a:router/1,2`
  mounts the routes and `handler/1` delegates to
  `barrel_a2a_http_engine:handle/6`. Livery owns the wire, the engine
  owns the protocol. See the [A2A guide](docs/guides/serve-a2a-agents.md).

### Changed

- `barrel_mcp` and `barrel_a2a` are declared as optional applications.
  Nothing in livery's core calls `livery_mcp` or `livery_a2a`, so a
  release that only serves HTTP is no longer forced to start two
  protocol stacks it never uses. An application that does use an adapter
  lists the library itself.

## [0.9.2] - 2026-08-30

Patch release: `h1` 0.9.1 fixes chunked request bodies that were rejected
when a socket segment split a chunk-size line between its CR and LF.

### Changed

- Bump `h1` 0.9.0 -> 0.9.1. A chunked request body was answered
  `400 Chunk size is not valid hex` whenever a socket read ended between
  the CR and LF of a chunk-size line; large uploads in many chunks hit it
  under load. HTTP/1.1 uploads through `livery_h1` no longer fail that way.

## [0.9.1] - 2026-08-30

Patch release: `barrel_mcp` 3.0.1 declares the same `h1`, `h2` and
`hackney` versions livery already uses, and the Early Hints guide is
listed in the generated docs.

### Changed

- Bump `barrel_mcp` 3.0.0 -> 3.0.1. Its dependency requirements now
  match livery's (`h1` 0.9, `h2` 0.12, `hackney` 4.7.4), so resolution
  no longer relies on livery's top-level pins winning.

### Fixed

- `docs/guides/early-hints.md` is registered with ex_doc, so the README
  link resolves and `rebar3 ex_doc` builds without warnings.

## [0.9.0] - 2026-08-30

Dependency release: `barrel_mcp` 3.0.0 brings MCP `2026-07-28` to the
`livery_mcp` endpoint, with one build-time behaviour change for `auth`.

### Changed

- Bump `barrel_mcp` 2.3.0 -> 3.0.0, which serves MCP `2026-07-28`
  alongside the earlier revisions on the same endpoint. Two changes
  reach `livery_mcp` users: an `auth` provider that refuses its options
  now makes `livery_mcp:handler/1` raise `{auth_provider, Module,
  Reason}` at build time instead of failing per request, and
  `barrel_mcp_auth_bearer` requires an `audience`. A legacy `tools/call`
  whose `Accept` lists `text/event-stream` is answered as an SSE stream
  whose final event is the result.

## [0.8.0] - 2026-08-12

### Added

- `https => #{..., alpn => [h2, http1]}` serves HTTP/2 and HTTP/1.1 from
  one TLS port, chosen per connection. Livery owns the listen socket
  (`livery_h1h2`), handshakes off the accept path, reads the negotiated
  protocol, and hands the socket to `h2:serve_socket/2` or
  `h1:serve_socket/2`; a client that offered no ALPN is served HTTP/1.1
  rather than dropped. The list is server preference order, so
  `[h2, http1]` means h2 wins when a client offers both. `alpn` defaults
  to `[h2]`, which is the previous h2-only behaviour.
- The H1 listener forwards h1's parser size limits: `max_line_length`,
  `max_request_line_size`, `max_empty_lines`, `max_header_name_size`,
  `max_header_value_size`, `max_headers`, `max_header_block_size`, and
  `pipeline`. They were selectable in h1 but unreachable through livery.
- `verify => verify_peer` on the H1 and H2 listeners, for mutual TLS.
  It requires `cacerts` and makes the client certificate mandatory; h1
  gained the option in 0.9.0, so it no longer silently does nothing on
  the H1 listener.
- The service's `host` is now used: with it set, `alt_svc => advertise`
  emits an authority-qualified `Alt-Svc` (`h3="example.com:443"`)
  instead of the port-only form. It was documented but read by nothing.
- `livery_service:listener_opts()` declares the options that already
  worked but went undeclared (`transport`, `ssl_opts`, the H1 timeouts,
  `settings`, `enable_connect_protocol`, ...) and says that anything
  else is forwarded to the adapter's own `listen_opts()`.
  `livery_h3:listen_opts()` declares `pool_size`.

### Changed

- **Breaking.** `livery:which_listeners/1` maps each protocol to a
  *list* of ports rather than a single port. One port can serve two
  protocols (an `alpn` listener) and one protocol can be on two ports (a
  cleartext `http` listener next to an `alpn` one), neither of which the
  old shape could express. `maps:get(h1, Listeners)` becomes
  `hd(maps:get(h1, Listeners))`.
- **Breaking for adapter callers.** The H1 and H2 `stream()` handle is
  now `{Connection, StreamId, Alpn}`. `peer_info/1` reports the ALPN the
  connection actually negotiated instead of a constant: `undefined` on a
  cleartext listener, and `undefined` for a TLS client that offered no
  ALPN.
- H2 requests carry `tls => #{}` on a TLS listener, as H1 requests
  already did, so `livery_req:tls/1` distinguishes h2 from h2c.

### Dependencies

- `h1` 0.9.0 (`serve_socket/2`, `verify`, `max_request_line_size`) and
  `h2` 0.12.0 (`serve_socket/2`).
- `webtransport` 0.4.5, which moves to `h2 ~> 0.12` so the WebTransport
  path and the listeners agree on one h2.
- `hackney` 4.7.4, which stops a wedged or timed-out connection from
  taking down the pool it belongs to, and with it every caller of that
  pool. `livery_client` runs on that pool.

## [0.7.0] - 2026-08-08

### Added

- `livery_req:inform/3` sends interim (1xx) responses, primarily
  `103 Early Hints`, ahead of the final response. Callable several times
  per request. Backed by a new optional adapter callback
  `send_informational/3`; supported on HTTP/1.1 (h1 0.8.0, skipped for
  HTTP/1.0 clients per RFC 9110 §15.2) and HTTP/2 (interim HEADERS, no
  END_STREAM per RFC 9113); HTTP/3 returns `{error, unsupported}` for
  now. `capabilities/1` advertises `informational`.
- `livery_req:peer/1` now carries the client address on plain HTTP
  requests on all three adapters (it was only set on the WebSocket
  handoff before), and `peer_info/1` returns the real peer. The H1
  adapter reads it from the connection (h1 0.8.0); H2/H3 from their
  connection state.
- `livery_ws:upgrade/3` accepts `max_frame_size` / `max_message_size`
  (frame decoder limits; a peer exceeding them is closed with 1009) and
  `compress => true` to negotiate permessage-deflate (RFC 7692, ws
  0.4.0) with clients that offer it.
- The test adapter records interim responses
  (`livery_test_adapter:informational/1`).

### Changed

- `livery:stop_service/1` now really cuts off in-flight and kept-alive
  HTTP/1.1 connections: h1 0.8.0 tracks accepted connections and
  `stop_server/1` closes them synchronously. Previously only the listen
  socket closed, so kept-alive clients were still served by a stopped
  service.
- `livery:drain/2` leaves established HTTP/1.1 connections serving
  through the drain window (`stop_accepting` no longer kills them) and
  closes the remaining idle keep-alive connections once the drain
  completes.
- WebSocket handlers' `terminate/2` receives `{remote, Code, Reason}`
  when the peer's close frame carried a status code (`remote` for a bare
  close), on every adapter (ws 0.4.0).
- Bump `h1` to 0.8.0, `quic` to 1.8.0 (RFC 6125 wildcard SAN matching,
  Happy Eyeballs backlog delivery on the winning attempt, Retry
  packet-number continuity, Version Negotiation handling), `ws`
  (erlang_ws) to 0.5.0 (RFC 8441 `Sec-WebSocket-Version` validation on
  extended CONNECT), `webtransport` to 0.4.4, `instrument` to 1.1.5
  (OTLP histogram encoding fixes), `hackney` to 4.7.3, `barrel_mcp` to
  2.3.0.
- Bump test and bench dependencies: `cowboy` to 2.18.0, `cowlib` to
  2.19.0, `ranch` to 2.2.1.
- Bump tooling: `erlfmt` to 1.8.0, `rebar3_lint` to 5.0.4 (elvis_core
  5.x), and migrate the elvis config to the new format.

## [0.6.1] - 2026-07-17

### Changed

- Bump hackney to 4.7.0. HTTP/2 request bodies larger than the peer's
  flow control window now block until the window opens (bounded by the
  new `send_timeout` request option) instead of failing with
  `{error, send_buffer_full}`, HTTP/2 async responses are delivered
  again, and `{async, once}` honors `stream_next/1`.

## [0.6.0] - 2026-07-16

### Added

- `livery_ws:upgrade/3` negotiates a WebSocket subprotocol. Pass
  `subprotocols => [binary()]` in the upgrade options: the first one the
  client also offers is echoed in the handshake response, and a client
  that offers none of them is rejected. Works on H1, H2, and H3.
- `livery_ws:upgrade/3` accepts `idle_timeout => timeout()` to override
  the session idle timeout (`infinity` never idle-closes), for long-lived
  connections such as SIP-over-WebSocket registrations.
- The WebSocket handler's `Req` now carries `peer => {IpAddress, Port}`,
  read from the accepted socket (H1), the h2 connection (H2), or the QUIC
  connection (H3). Requires h2 >= 0.11.0 and quic >= 1.7.0.

### Fixed

- A streamed client response (`stream => true`) run through
  `livery_client:timeout/1` no longer crashes with `{noproc, _}`. The
  timeout worker owned the hackney connection and tore it down on exit
  before the caller could read the body; it now hands the connection to
  the caller via a new optional adapter callback `adopt/2`. Requires
  hackney >= 4.6.0.

## [0.5.2] - 2026-07-07

### Changed

- Bump wire dependencies to their latest hex releases: hackney 4.5.2,
  h2 0.10.4, webtransport 0.4.3, quic 1.7.0.

## [0.5.1] - 2026-07-05

### Fixed

- `max_body` now governs the HTTP/1.1 request-body limit end to end.
  It previously bounded only livery's translator while h1's parser kept
  its own 8 MiB default, so any `max_body` above 8 MiB was silently
  capped and uploads past 8 MiB were lost. The H1 adapter now disables
  h1's parser cap and enforces `max_body` itself, returning a graceful
  413 on exceed. Requires erlang_h1 >= 0.7.1.

### Changed

- `livery:start_service/1` listener options accept `max_body`
  (`non_neg_integer() | infinity`, default 16 MiB), now documented and
  type-checked.

## [0.5.0] - 2026-07-04

Adds first-class support for the HTTP QUERY method (RFC 10008), end to
end: server, client, OpenAPI, example, and docs.

### Added

- HTTP QUERY method support. The core was already method-agnostic
  (router dispatch, the 405 `Allow` header, body reading, all three
  adapters), and the parity suite now locks QUERY-with-body behaviour
  across HTTP/1.1, HTTP/2, and HTTP/3.
- `livery_client:query/3`, mirroring `post/3`. The retry layer treats
  QUERY as idempotent and replays it.
- A `QUERY /notes` search endpoint in the complete example, exercised
  by the e2e journey, and a new guide: `docs/guides/query-method.md`.

### Changed

- `livery_openapi` emits OpenAPI 3.2.0 documents (previously 3.1.0);
  QUERY routes appear as the `query` operation, a first-class key in
  3.2.
- `livery_cors` includes `QUERY` in the default allow-methods.
- Bump `hackney` 4.4.5 -> 4.5.1.

## [0.4.4] - 2026-06-18

Maintenance release: dependency update.

### Changed

- Bump `hackney` 4.4.3 -> 4.4.5.

## [0.4.3] - 2026-06-17

Maintenance release: a disconnect-handling fix and a dependency bump.

### Fixed

- Handle a peer disconnect mid-response gracefully. A client closing the
  connection before the response was written crashed the request worker
  twice and logged ERROR and CRASH reports for a normal disconnect. The
  H1 and H3 send paths now map a dead connection to `{error, closed}` (as
  H2 already did), and the worker treats a closed connection as a benign
  early termination instead of a handler crash.

### Changed

- Bump `hackney` 4.4.2 -> 4.4.3.

## [0.4.2] - 2026-06-17

Adds a cookie jar client layer.

### Added

- Cookie jar client layer (`livery_client:cookie_jar/0,1`). Stores the
  cookies a response sets and sends the matching ones (host, path, secure)
  on later requests through the layer, following the RFC 6265 client
  subset. Backed by a pluggable `livery_client_cookie_store` (default
  in-memory ETS); `max_cookies` caps the jar before the oldest are evicted.

## [0.4.1] - 2026-06-16

Maintenance release: dependency updates.

### Changed

- Bump `webtransport` 0.4.0 -> 0.4.1, `hackney` 4.4.0 -> 4.4.2, and
  `barrel_mcp` 2.2.3 -> 2.2.4.

## [0.4.0] - 2026-06-16

Adds early-response draining on HTTP/1.1 and request authority/scheme on
HTTP/2, with wire-dependency bumps.

### Added

- Early-response inbound drain on HTTP/1.1. When a handler commits a full
  response before the request body is read (for example a 413 rejecting an
  oversized upload), the leftover inbound body is drained before the socket
  closes, so the client reads the response instead of a connection reset.
  New per-response `early_response_drain` field on the response, with
  `livery_resp:with_early_response_drain/2` and `early_response_drain/1`,
  and `livery_resp:json/4` and `text/4` taking a response-options map. New
  `early_response_drain` and `lingering_timeout` listener options. The
  per-response override applies to full responses; streaming responses use
  the listener budget.
- HTTP/2 requests populate `livery_req:authority/1` and `livery_req:scheme/1`
  from the `:authority` and `:scheme` pseudo-headers, and synthesize a
  `host` header from the authority when the client omits one, so host-based
  routing works without a `host` header. The pseudo-headers are stripped
  from the application-visible headers.

### Changed

- Bump `h1` 0.6.2 -> 0.7.0 and `h2` 0.10.1 -> 0.10.2.
- HTTP/1.1 over TLS records `tls` on the request, so `livery_req:tls/1`
  reflects a secure connection.

### Fixed

- `wss://` (HTTPS WebSocket) upgrades on HTTP/1.1. The adapter now hands the
  ws session the TLS transport for an accepted SSL socket instead of always
  using the plain-TCP transport.
- An HTTP/1.1 request body that exceeds the listener `max_body` no longer
  resets the stream: the handler's response is delivered and the rest of the
  inbound body is drained before closing.

## [0.3.2] - 2026-06-14

Maintenance release: dependency updates.

### Changed

- Bump `h2` 0.9.0 -> 0.10.1, `hackney` 4.3.0 -> 4.4.0, and `barrel_mcp`
  2.2.2 -> 2.2.3.
- Require the wire dependencies (`h1`, `h2`, `quic`, `ws`, `instrument`,
  `webtransport`, `hackney`, `barrel_mcp`) with `~>` so patch releases
  are accepted automatically.
- Bump the cowboy comparison harness to cowboy 2.16.1 and cowlib 2.17.1,
  and `proper` to 1.5.0, in the test and bench profiles.

## [0.3.1] - 2026-06-14

Maintenance release: an `instrument` bump and a documentation pass.

### Changed

- Upgrade `instrument` 1.1.3 -> 1.1.4.

### Documentation

- Rewrote the guides, tutorials, and concept pages in a task-oriented
  style. Each page opens with what it is and when you need it, then the
  concrete steps.
- Added an Ecosystem page linking the sibling libraries `livery_grpc`,
  `livery_s3`, and `livery_stripe`, on the site and in the API reference.

## [0.3.0] - 2026-06-13

Adds deferred responses, per-SNI certificate selection on HTTP/3, and
per-listener TLS options, with wire-dependency bumps.

### Added

- `livery_resp:stream_deferred/1`. The resolver fun runs at emit time, in
  the worker, before any header is written, and chooses the response shape:
  `{stream|sse|ndjson, Status, Headers, Producer}` or `{full, Status,
  Headers, Body}`. This lets a streaming handler reply with a non-2xx JSON
  error if admission fails before the first byte, instead of `200 OK` + an
  in-band error frame. Headers added by wrapping middleware merge under the
  decision's headers (decision wins on conflict).
- Per-SNI certificate selection on HTTP/3. `livery_h3` forwards a
  `sni_callback` (carried inside `quic_opts`) so an H3 listener picks its
  certificate per connection from the ClientHello SNI, mirroring the
  `ssl_opts`/`sni_fun` path on H1/H2. See
  `docs/guides/serve-multiple-certs-sni.md`.
- Per-listener TLS `ssl_opts` are forwarded to the underlying listeners.

### Changed

- Bump `h1` 0.6.1 -> 0.6.2, `quic` 1.6.4 -> 1.6.5, `webtransport`
  0.3.3 -> 0.4.0, `hackney` 4.2.3 -> 4.3.0.

## [0.2.7] - 2026-06-10

Maintenance release: a Hex resolution fix, an HTTP/1.1 WebSocket header
fix, and a push-streaming mode for the HTTP client.

### Added

- `livery_client` push streaming. Pass `stream_to => Pid` (with `stream
  => true`) and the response is delivered to `Pid` as ordered messages
  (`{livery_response, Ref, {status, Status, Headers}}`, `{chunk, Binary}`,
  `done`, `{error, Reason}`), so one process can interleave body chunks
  with its own control messages in a selective receive instead of
  dedicating a process to a blocking read loop. `flow => manual` sends one
  chunk per `stream_next/1` for backpressure; `stop_stream/1` cancels and
  drops the connection. The `livery_client_adapter` behaviour gains
  optional `stream/3`, `stream_next/1`, and `stop_stream/1` callbacks. The
  pull-based `{stream, Reader}` + `read/2` API is unchanged.

### Fixed

- The package now resolves on Hex (#49). The published dependency pins
  conflicted: `barrel_mcp` 2.2.0 required `hackney` 4.0.3 / `h2` 0.6.1 /
  `erlang_h1` ~>0.2.3, and `hackney` 4.2.2 required `h2` 0.8.0, neither
  of which agrees with Livery's own pins. The dependency bumps below put
  the whole graph on `h2` 0.9.0. (Local builds use git deps, which skip
  Hex version resolution, so the conflict never showed up in CI.)
- HTTP/1.1 WebSocket upgrade: the `101 Switching Protocols` response no
  longer carries duplicate `Connection`/`Upgrade` headers, which
  spec-strict clients (Safari, undici) reject. Fixed upstream in
  `erlang_h1` 0.6.1, which now owns those framing headers and strips any
  caller-supplied copies.

### Changed

- Bump dependencies onto a mutually compatible set:
  - `barrel_mcp` 2.2.0 -> 2.2.2 (now requires `hackney` 4.2.3 / `h2`
    0.9.0 / `erlang_h1` ~>0.6.1)
  - `erlang_h1` 0.6.0 -> 0.6.1
  - `hackney` 4.2.2 -> 4.2.3 (now requires `h2` 0.9.0)
  - `webtransport` 0.3.2 -> 0.3.3

## [0.2.6] - 2026-06-09

Maintenance release: a `barrel_mcp` bump that threads the authenticated
principal into MCP tool handlers. No Livery API change.

### Changed

- Bump `barrel_mcp` 2.1.0 -> 2.2.0. Arity-2 MCP tool handlers
  (`Mod:Fun(Args, Ctx)`) now receive the authenticated principal in
  `Ctx` under `auth_info`, so owner-scoped tools can identify the
  caller. The handler passes it through unchanged; no Livery API change.

## [0.2.5] - 2026-06-07

Maintenance release: HTTP client fixes and a `Retry-After`-aware retry
layer. No API change beyond the new retry option.

### Added

- The retry layer honors a `Retry-After` (delta-seconds) header on a
  retryable response, sleeping that long instead of the computed backoff,
  capped by the new `retry_after_max` option (default 120000 ms). An
  HTTP-date `Retry-After` falls back to backoff.

### Fixed

- The hackney client adapter no longer crashes on a bodyless response
  (HEAD, 204, 304), where hackney returns a three-tuple with no body.

### Changed

- Bump `hackney` 4.2.1 -> 4.2.2.

## [0.2.4] - 2026-06-06

Maintenance release: an HTTP/2 write-path optimization, an HTTP/2
disconnect fix, and a runtime concurrency-cap setter. No API change
beyond the added setter.

### Changed

- Bump `h2` to 0.9.0, which coalesces a response's frames into a single
  socket write instead of one write per frame. On the loopback benchmark
  this roughly doubles large HTTP/2 response throughput (100 KiB over TLS:
  ~28k -> ~66k req/s) and lifts smaller bodies ~7-9%.

### Fixed

- HTTP/2: a client that disconnects mid-response is reported as a normal
  disconnect (`{error, closed}`, matching HTTP/1.1's `gen_tcp:send`)
  instead of crashing the request. The crash path error-logged the full
  stacktrace, which carries the response body as a send argument, so a
  disconnect during a large response pretty-printed the whole body per
  request - a throughput sink and a log-hygiene leak.

### Added

- `livery_req_sup:set_max_concurrent_requests/1` changes the in-flight
  request cap at runtime. The cap is resolved once at startup and cached
  in `persistent_term` rather than read from the application environment
  on every request.

### Benchmarks

- `bench/compare.sh` compares livery, cowboy, and bandit over HTTP/1.1
  (`wrk`) and HTTP/2 over TLS (`h2load`) across realistic workloads (tiny
  GET, 1/10/100 KiB sized responses served from a cached payload, JSON
  echo `POST`), with a per-protocol summary table and an optional
  concurrency sweep.

## [0.2.3] - 2026-06-05

Maintenance release: dependency bumps and benchmark tooling. No API change.

### Changed

- Bump wire dependencies: `h1` (erlang_h1) 0.5.0 -> 0.6.0 (cuts
  per-request allocations, single-scan header parsing, one-pass response
  header block, header-block size cap), `quic` 1.6.3 -> 1.6.4, `hackney`
  4.2.0 -> 4.2.1, `webtransport` 0.3.1 -> 0.3.2.

### Added

- HTTP/3 in the cross-server benchmark (`bench/compare.sh`), measured with
  livery's in-VM `quic_h3` driver (livery only; cowboy and bandit have no
  HTTP/3), alongside the HTTP/1.1 (`wrk`) and HTTP/2-over-TLS (`h2load`)
  comparisons.

## [0.2.2] - 2026-06-05

Maintenance release: an H1 throughput optimization and benchmark tooling.
No API change.

### Changed

- H1 full responses coalesce into a single `content-length` socket write
  (`livery_h1:send_full/5` via the new `h1:respond/5`) instead of chunked
  framing over two writes, lifting H1 throughput about 24% in the loopback
  benchmark. Requires erlang_h1 0.5.0 (bumped from 0.4.0).

### Added

- Cross-server benchmark (`bench/compare.sh`) comparing livery, cowboy,
  and bandit over HTTP/1.1 (`wrk`) and HTTP/2 over TLS (`h2load`).

## [0.2.1] - 2026-06-04

Maintenance release: tests, docs, and internal layout. No API or
behaviour change.

### Added

- End-to-end test suite (`livery_e2e_SUITE`): boots the example notes
  service over H1, H2, and H3 and runs the same CRUD + middleware + SSE +
  WebSocket journey against each protocol.

### Changed

- Source tree grouped into domain subdirectories (`src/client`,
  `src/middleware`, `src/auth`, `src/codec`); the core runtime stays flat
  in `src/`. Pure relocation, no module renamed.
- README rewritten around runnable snippets.
- The example service registers its `/ws` route for any method, so the
  WebSocket upgrade works over H2/H3 extended CONNECT as documented.

## [0.2.0] - 2026-06-04

Closes the structural gap with Axum + Tower + Hyper: router composition,
first-class shared state, and a composable HTTP client that mirrors the
middleware model outbound, including load balancing across endpoints.

### Added

- Router composition. `livery_router:nest/2,3` mounts a sub-router under a
  path prefix and `livery_router:merge/1,2` combines routers, so an area
  (for example an MCP mount) can be assembled on its own and grafted in.
- First-class service config. `livery:start_service/1` takes a `config`
  map shared by every handler and middleware, read with
  `livery_req:config/1,2,3` (the `with_state` analogue).
- Composable HTTP client (`livery_client`): the outbound twin of the
  middleware. Build a client with a transport adapter, base URL, default
  headers, and a layer stack, then call it. Ships timeout, retry,
  concurrency-limit, and circuit-breaker layers, streamed request and
  response bodies, and a `livery_client_adapter` behaviour (default
  `livery_client_hackney`, covering HTTP/1.1, HTTP/2, and HTTP/3).
- Client load balancing. A `livery_client:balance/1` layer spreads
  requests across a pool of endpoints with power-of-two-choices or
  round-robin selection, passive outlier ejection, and lazy half-open
  recovery. Pools are seeded from a static list or a
  `livery_client_discover` provider and can be changed at runtime with
  `add_endpoint/2` and `remove_endpoint/2`.
- Bind to a specific listen address, including IPv6 (`livery_inet`), and
  reduced per-request overhead.
- Cowboy cutover validation. `examples/livery_example_migration.erl`
  expresses the common Cowboy patterns (plain handler, REST resource,
  SSE, a `cowboy_loop`-style streaming endpoint, WebSocket echo) in
  Livery, and `test/livery_cowboy_parity_SUITE.erl` runs that handler set
  behind both a live Cowboy listener and Livery, diffing the observable
  behaviour over H1, then drives the same Livery handlers over H2 and H3.

### Changed

- Wire dependencies moved to hex and bumped: `quic` 1.6.3, `h2` 0.8.0,
  `webtransport` 0.3.1, `hackney` 4.2.0, `instrument` 1.1.3.

### Fixed

- H1 query string handling.
- Low-severity security hardening across the adapters.

## [0.1.0] - 2026-05-26

First public release. Livery is a BEAM-native web framework that serves
one handler set over HTTP/1.1, HTTP/2, and HTTP/3 from a single service
runtime, in the spirit of Axum + Tower + Hyper. This is an early (0.x)
release; the framework is still under active development.

### Core

- Multi-protocol service runtime (`livery:start_service/1`) that brings
  H3 (UDP), H2 (TLS), and H1 (TCP) up together under one router and
  middleware stack and advertises `Alt-Svc` for H3. Single-protocol
  listeners via `livery:start_listener/2`.
- Thin H1/H2/H3 adapters over the sibling wire libraries (`h1`, `h2`,
  `quic`); externally observable behaviour is locked across all adapters
  by a parity test suite.
- Per-request worker model (`livery_req_proc`) with a per-stream
  translator that forwards wire events, so handlers may block and
  receive.
- Value-based Tower/Axum middleware (`call(Req, Next, State) -> Resp`),
  with global and per-route stacks.
- Immutable request/response values (`livery_req`, `livery_resp`) and a
  radix-trie router (`livery_router`).
- Response body variants: full, chunked, SSE, file, empty, and upgrade.
- Graceful shutdown via `livery_drain` and cancel-on-disconnect across
  H1/H2/H3.

### Protocols and streaming

- WebSocket over H1, H2, and H3.
- WebTransport upgrade bridge over H3.
- Server-Sent Events and file responses streamed over every adapter.
- MCP Streamable HTTP handler over `barrel_mcp` 2.0.

### Middleware and helpers

- CORS (`livery_cors`) and security headers (`livery_security_headers`).
- Response compression (`livery_compress`) over a pluggable
  `livery_codec` registry, with gzip and deflate built in.
- Multipart and streaming form-body parsing (`livery_multipart`,
  `livery_ext:read_form/1,2`).
- Concurrency-limit load shedding (`livery_concurrency`) and per-key
  rate limiting (`livery_ratelimit`).
- HTTP caching: automatic ETag and conditional GET (`livery_etag`) plus
  `livery_resp:with_etag/2` and `with_cache_control/2`.
- Static-directory serving (`livery_static`) with MIME by extension,
  weak ETag, Range, directory index, and strict path confinement.
- Health and readiness endpoints (`livery_health`) and a Prometheus
  `/metrics` handler (`livery_metrics`).

### Auth and API tooling

- Signed session cookies and RFC 7662 token introspection.
- Bearer middleware with OIDC discovery and JWKS fetch, cache, and
  rotation.
- OpenAPI request validation with inline Redoc and Swagger UI handlers.

### Observability

- OpenTelemetry-style tracing and HTTP server metrics over the
  `instrument` library, with a logger bridge that carries trace context
  into log events.
- Metrics middleware (`livery_instrument_metrics`) is best-effort and
  resolves instruments from the `instrument` registry on each request, so
  it never fails a request and self-heals after a registry restart
  (requires `instrument` 1.1.2).

### Notes

- In the bundled in-VM benchmark harness, H3 throughput is bounded by the
  QUIC round trip because the client and server share one BEAM. Measure
  H3 with an external native QUIC client.

[0.3.2]: https://github.com/benoitc/livery/releases/tag/v0.3.2
[0.3.1]: https://github.com/benoitc/livery/releases/tag/v0.3.1
[0.3.0]: https://github.com/benoitc/livery/releases/tag/v0.3.0
[0.2.7]: https://github.com/benoitc/livery/releases/tag/v0.2.7
[0.2.6]: https://github.com/benoitc/livery/releases/tag/v0.2.6
[0.2.5]: https://github.com/benoitc/livery/releases/tag/v0.2.5
[0.2.4]: https://github.com/benoitc/livery/releases/tag/v0.2.4
[0.2.3]: https://github.com/benoitc/livery/releases/tag/v0.2.3
[0.2.2]: https://github.com/benoitc/livery/releases/tag/v0.2.2
[0.2.1]: https://github.com/benoitc/livery/releases/tag/v0.2.1
[0.2.0]: https://github.com/benoitc/livery/releases/tag/v0.2.0
[0.1.0]: https://github.com/benoitc/livery/releases/tag/v0.1.0
