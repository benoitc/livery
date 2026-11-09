# Agents

Instructions for AI coding agents working on this project.

## Project Overview

Livery is a BEAM-native web framework that serves one handler set
over HTTP/1.1, HTTP/2, and HTTP/3 from a single service runtime
(the spirit of Axum + Tower + Hyper on the BEAM). The wire layer is
delegated to sibling hex libraries; Livery owns the developer
surface. One OTP application; core runtime stays at the `src/` top
level, with subsystems grouped into domain subdirectories (rebar3
compiles `src/` recursively):

```
src/            Core runtime, flat: livery, livery_req, livery_resp,
                livery_router, livery_service, livery_h1/h2/h3,
                livery_ws*, livery_wt, livery_mcp, livery_openapi,
                livery_static, livery_metrics, ... (+ livery.app.src)
src/client/     Outbound HTTP client: livery_client + its layers,
                stores, adapter, and discovery
src/middleware/ livery_middleware framework + cross-cutting middlewares
                (request_id, access_log, cors, etag, timeout, ratelimit
                (+ store), concurrency, security_headers, alt_svc,
                instrument_*, openapi_validate, body_limit)
src/auth/       Auth middlewares + helpers (bearer, introspect, session,
                jwks, oidc, livery_auth)
src/codec/      Content-coding subsystem (livery_compress + codecs)
include/    Shared records (livery.hrl)
test/       EUnit + Common Test (incl. the cross-adapter parity SUITE
            and livery_e2e_SUITE, a full journey over H1/H2/H3)
bench/      Load/latency harness (separate `bench` rebar profile)
examples/   Runnable example apps (`examples` rebar profile)
docs/       Diataxis docs (tutorials/guides/concepts) + design notes
```

Wire dependencies (`h1`, `h2`, `quic`, `ws`, `webtransport`,
`instrument`, `barrel_mcp`) are git deps in `rebar.config`. Local
development overrides them with `_checkouts/` symlinks to the
sibling projects; `_checkouts/` is gitignored. Never reimplement
HPACK/QPACK/frame/QUIC logic here: that lives in the wire libs;
keep the adapters thin and push changes upstream.

Authoritative behaviour is the test suites under `test/` (the
parity SUITE diffs externally observable behaviour across all four
adapters) and the module docs.

## Specification issues are bugs, not security issues

A report is a specification issue when the fix is to make Livery do what a
spec it implements says (see [Specifications](#specifications)), or to make a
limit one of its options defines hold:

- a request accepted, rejected or answered differently from the spec:
  status, fields, `Vary`, conditional requests, ranges, content coding,
  multipart, SSE framing, cookie parsing;
- a limit not holding: `max_body`, `livery_body_limit`, `livery_timeout`,
  `livery_ratelimit`, `livery_concurrency`, the H1 slow-client guards;
- behaviour that differs across adapters where the parity suite says it
  should not.

This holds even when the report calls it denial of service, resource
exhaustion or a remote crash. Treat it as a bug:

- fix it in a public pull request, with a public issue if one is needed;
- list it under **Fixed** in the CHANGELOG, in plain English, citing the spec
  section or the option;
- do not open a GitHub Security Advisory, request a CVE, embargo the fix,
  give it a severity, or describe how to attack it;
- when it arrived as an advisory, close the advisory as not a vulnerability
  and link the pull request that fixes it.

A problem in framing, header compression, flow control or the TLS handshake
is not Livery's: it belongs to the wire library that does it (see
[CONTRIBUTING.md](CONTRIBUTING.md#where-to-report)) and goes upstream under
that project's policy. Do not work around it in an adapter.

Only a problem that lets someone past what the configuration protects goes
through [SECURITY.md](SECURITY.md): code execution, or request data turned
into atoms or terms; a request accepted without the authentication or
authorization the configuration asks for (bearer and JWT checks, token
introspection, session cookies, OIDC and JWKS, client certificates); one
request's, session's or connection's data reaching another client;
`livery_static` serving outside its root; CORS granting an origin the
configuration does not allow; the client sending credentials or cookies to
another host; Livery weakening TLS below what the configuration asks for.
Authentication stays a security issue even where a spec describes the
check. If unsure, ask the maintainer before treating anything as a security
issue.

## Required Checks

Every change must be formatted and pass all checks before committing:

```bash
rebar3 fmt          # Auto-format (always run first)
rebar3 compile      # Must compile cleanly (warnings_as_errors)
rebar3 lint         # Elvis linter
rebar3 as check xref      # Cross-reference analysis
rebar3 as check dialyzer  # Type checking
rebar3 eunit        # Unit + property tests
rebar3 ct           # Common Test (adapters, parity, service, ws, wt, mcp)
```

CI (`.github/workflows/ci.yml`) runs `format`, `lint`, `xref`, and
`dialyzer` as fast-fail static checks, then gates `build`/`eunit`/
`ct` on them.

## Pull Requests

Work on one issue goes in one pull request. Give each change a reviewer has
to look at its own commit, with its tests. Docs and CHANGELOG entries go in
the same pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for the rest of
the workflow.

- Every bug fix and feature has a test. Show it failing on main.
- A change to how Livery reads or answers requests (routing, headers,
  caching, ranges, content coding, cookies, CORS, auth) is checked against
  the spec section it cites, that spec being the current one, and safety
  against a hostile client, before it is opened.
- Never relax a limit or a check to make a client pass; exclude the
  legitimate case precisely.
- Descriptions state what was wrong, the fix in a few lines, and breaking
  changes. Reference issues with `Fixes #N`. No test plan, no file-by-file
  or commit-by-commit walkthrough.
- No `Co-Authored-By`, "Generated with" or similar trailers, in commits or
  pull requests.
- CHANGELOG: plain English, what was wrong and what it means for the user,
  the spec section when there is one. No implementation details, no attack
  narratives.
- Follow "Write for the person who reads it" in
  [CONTRIBUTING.md](CONTRIBUTING.md#write-for-the-person-who-reads-it): plain
  English, no inflated or pseudo-technical wording, and a person has read
  the change before it is opened.

## Specifications

What Livery implements itself. Wire framing (RFC 9112, 9113, 9114, 9000,
9204, 6455 and the WebTransport drafts) is delegated to the wire libraries.

| Spec | Scope in Livery | Code |
|---|---|---|
| RFC 9110 HTTP semantics | methods, status, fields, conditional requests, ranges, content coding | `livery_router`, `livery_req`, `livery_resp`, `livery_static`, `livery_etag`, `livery_compress` |
| RFC 9111 HTTP caching | validators, 304, `Vary` | `livery_etag`, `livery_compress` |
| RFC 1950, 1951, 1952 | zlib, deflate and gzip codings | `src/codec/` |
| RFC 7578 multipart/form-data | form and upload parsing | `livery_multipart` |
| RFC 6265 cookies | session cookies, client cookie jar | `livery_auth_session`, `livery_client_cookie` |
| Fetch standard, CORS | preflight and response headers | `livery_cors` |
| HTML, server-sent events | `text/event-stream` framing | `livery_resp`, `livery` |
| RFC 6797 HSTS | `Strict-Transport-Security` and the other security headers | `livery_security_headers` |
| RFC 7838 Alt-Svc | advertising HTTP/3 | `livery_alt_svc`, `livery_service` |
| RFC 8441, RFC 9220 extended CONNECT | WebSocket and WebTransport handoff | `livery_ws`, `livery_wt`, `livery_h2`, `livery_h3` |
| RFC 6750 bearer tokens (updated by RFC 9700) | `Authorization: Bearer`, `WWW-Authenticate` challenges, 401/403 | `livery_auth_bearer`, `livery_auth_challenge` |
| RFC 7515, 7517, 7518, 7519 JWS, JWK, JWA, JWT | token verification, key selection, key sets | `livery_auth`, `livery_auth_jose`, `livery_auth_jwks` |
| RFC 9864 fully-specified JOSE algorithms | Ed25519, Ed448 | `livery_auth_jose` |
| RFC 8725 JWT best current practices | algorithm allow list, explicit typing on request | `livery_auth`, `livery_auth_jose` |
| RFC 9068 JWT access token profile | `profile => access_token` | `livery_auth` |
| RFC 7662 token introspection | introspection client, audience and scope checks | `livery_auth_introspect` |
| RFC 8414 authorization server metadata | `discover_oauth/1,2` | `livery_auth_oidc` |
| RFC 8705 certificate-bound access tokens | `cnf.x5t#S256` against the client certificate | `livery_auth_binding` |
| RFC 9449 DPoP | proof checks, `cnf.jkt`, `DPoP` scheme and challenge, server nonces | `livery_auth_dpop`, `livery_auth_binding`, `livery_auth_dpop_store` |
| RFC 7638 JWK thumbprint | DPoP key thumbprint | `livery_auth_dpop` |
| RFC 6749 (client side, updated by RFC 9700) | token requests, client authentication, client credentials and authorization code grants | `livery_auth_token`, `livery_client_oauth`, `livery_auth_login` |
| RFC 7523 (updated by RFC 10070) | `private_key_jwt` client assertions | `livery_auth_token` |
| RFC 7636 PKCE | S256 challenge on every login | `livery_auth_login` |
| RFC 8707 resource indicators | `resource` on token requests | `livery_auth_token` |
| RFC 9207 issuer identification | `iss` check on the authorization response | `livery_auth_login` |
| OpenID Connect Core 1.0 | authorization code flow, ID token validation | `livery_auth_login` |
| OpenID Connect RP-Initiated Logout 1.0 | logout redirect to `end_session_endpoint` | `livery_auth_login` |
| RFC 9728 protected resource metadata | metadata document, `resource_metadata` challenge parameter | `livery_auth_resource`, `livery_auth_challenge` |
| OpenID Connect Discovery 1.0 | provider metadata | `livery_auth_oidc` |
| OpenAPI 3.2, JSON Schema (subset) | document generation, request validation | `livery_openapi`, `livery_openapi_validate` |

### Known deviations

Where Livery knowingly does something other than what a spec says, it is
listed here with the reason, and the module doc of the code that does it
says so too. Add the entry in the same pull request as the code. A
deviation that is not listed is a bug: fix the code or add it here. A
report about a listed deviation is answered with its reason, not
treated as a new bug.

| Spec | What Livery does instead | Why | Code |
|---|---|---|---|
| RFC 9864 section 2 | still accepts the deprecated `EdDSA` name, with the curve from the key | most issuers still send it | `livery_auth_jose` |
| RFC 8725 section 3.11 | does not require `typ` unless asked (`typ` option or `profile => access_token`) | most issuers send `JWT` or nothing, so requiring it would refuse their tokens | `livery_auth` |
| RFC 9068 section 2.2.3 | reads the `scp` list as well as `scope` | Azure AD and Okta issue `scp` | `livery_auth` |
| RFC 7662 section 4 | does not cache introspection answers | a cache has to stay shorter than each token's life, which only the application can judge | `livery_auth_introspect` |
| OpenID Connect Discovery 1.0 section 3, RFC 8414 section 2 | checks only `issuer`, not the other REQUIRED metadata | the document is handed back as is; `issuer` is the field discovery has to trust | `livery_auth_oidc` |
| RFC 9449 section 11.1 | remembers used proofs per node, not across a cluster, unless `dpop_replay` is set | Livery has no shared store of its own | `livery_auth_dpop_store` |
| RFC 9728 section 3.3 | does not check that `resource` is the URL clients use | only the application knows its public URL | `livery_auth_resource` |
| RFC 10070 section 2 | `assertion_audience => token_endpoint` puts the token endpoint in the assertion's `aud`, which RFC 10070 no longer allows; off by default | some authorization servers still expect the old audience | `livery_auth_token` |
| OpenID Connect Core 1.0 section 3.1.3.8 | `at_hash` is not checked for Ed448 ID tokens | the spec names no hash for that curve | `livery_auth_login` |
| RFC 6265 section 5.3 step 5 | no public suffix list; refuses single-label domains instead | no dependency ships the list | `livery_client_cookie` |
| RFC 6265bis `SameSite` | parsed but not enforced by the client jar | the jar has no notion of the site a request comes from | `livery_client_cookie` |
| JSON Schema 2020-12 | OpenAPI request validation covers a subset of keywords | a full validator is out of scope | `livery_openapi_validate` |
| (file serving) | symlinks below the static root are checked before the file is opened, not at open | OTP cannot open a path without following links | `livery_static` |

## Build & Development Commands

```bash
rebar3 compile                              # Build
rebar3 shell                                # Boot a dev shell
rebar3 ct --suite=test/livery_parity_SUITE  # One suite
rebar3 fmt                                   # Auto-format (erlfmt)
rebar3 fmt --check                           # Format check, no writes
rebar3 lint                                  # Elvis linter
rebar3 as bench shell                        # Benchmark harness (livery_bench)
```

## Architecture

### Service runtime

`livery:start_service/1` brings H3 (UDP), H2 (TLS), and H1 (TCP) up
together under one `livery_service` gen_server, sharing one router
and middleware stack, and advertising `Alt-Svc` for H3 on H1/H2
responses. `livery:start_listener/2` serves a single protocol.
`livery_drain` gives graceful shutdown (stop accepting, wait for
in-flight, then stop).

### Per-request worker model

Each adapter, on a new request, spawns a `livery_req_proc` child of
the single global `livery_req_sup` (simple_one_for_one) and returns
immediately. A per-stream "translator" process forwards wire events
(`{h1_stream,_}` / `{h2,_}` / `{quic_h3,_}`) to the worker as
`{livery_body, Ref, _}` messages; the translator monitors the
worker and exits on its `DOWN`. Middleware and the handler run in
the worker, which may block/`receive` (the `cowboy_loop` analogue).

### Middleware (Tower/Axum style)

`call(Req, Next, State) -> Resp`: a continuation over immutable
values, not the legacy `(req, res, next)` mutate-and-next model.
Routes may carry a per-route stack under the route `Meta`'s
`middleware` key.

### Dispatch and emit

The handler returns a `#livery_resp{}`; `livery:emit/3` walks the
body variant (`full` / `chunked` / `sse` / `file` / `empty` /
`upgrade`) and drives `Adapter:send_headers/send_data/send_trailers`.
The `taken_over` sentinel tells `emit/3` to stop because the stream
was handed off (WebSocket, WebTransport, MCP).

### Adapter behaviour

`livery_adapter` defines `start/3`, `stop/1`, `send_headers/4`,
`send_data/3`, `send_trailers/2`, `reset/2`, `peer_info/1`,
`capabilities/1`. Implemented by `livery_h1`, `livery_h2`,
`livery_h3`, and `livery_test_adapter` (in-memory, used by the
parity SUITE).

## Conventions

- Run `rebar3 fmt` before committing; elvis must pass. New
  per-module elvis ignores belong in `rebar.config` with a one-line
  reason.
- Commit messages: one imperative subject line, body only for
  non-obvious "why". No phase references, no diff restatement, no
  "generated by" / "co-authored-by" trailers.
- Do not use the em-dash character in code, docs, or messages.
- Keep adapters thin; cross-protocol behaviour is locked by the
  parity SUITE from Phase 2 forward.
- TLS `verify_none` is test-only; never ship it in `src/`.
- File responses (`livery_resp:file/2,3`) serve the exact path
  given; confine any handler-built path before serving.
