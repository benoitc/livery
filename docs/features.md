# Follow-ups

Tracked work that is not yet scheduled. Upstream items link to the
sibling library that owns the change.

## Framework-gap backlog (from the audit)

Modern web/AI framework gaps, in priority order. Steps 1-8 are done.

1. Cancel on client disconnect. DONE: `livery_req:on_disconnect/2`
   plus the `{livery_disconnect, _, _}` message, delivered across
   H1/H2/H3 by the per-stream translator (which monitors the
   connection). See `docs/guides/cancel-on-disconnect.md`.
2. CORS middleware. DONE: `livery_cors` (preflight short-circuit,
   origin allowlist/predicate, credentials, expose, max-age, and
   cache-correct `Vary`). See `docs/guides/enable-cors.md`.
3. Response compression with Accept-Encoding. DONE (gzip + deflate):
   `livery_compress` negotiates over the `livery_codec` registry and
   compresses full + chunked bodies; `livery_codec_gzip` and
   `livery_codec_deflate` are built in over OTP `zlib`. See
   `docs/guides/compress-responses.md`. Follow-up codec apps (separate
   PRs, link system libs): `livery_brotli` (NIF, `br`) and
   `livery_zstd` (cmake NIF, `zstd`) implement the same behaviour and
   self-register via `livery_codec:register/1`.
4. Multipart / form-data body parsing (uploads, multimodal). DONE:
   `livery_multipart` (streaming pull parser + `read_all`, bounded
   buffering, filename returned verbatim) and `livery_ext:read_form/1,2`
   (streaming urlencoded). See `docs/guides/handle-file-uploads.md` and
   `docs/guides/parse-form-bodies.md`.
5. Concurrency limit / load-shedding middleware (admission control).
   DONE: `livery_concurrency` (`limiter/1,2` factory over a lock-free
   `atomics` counter; over the limit sheds `503` immediately, optional
   Retry-After). See `docs/guides/limit-concurrency.md`.
6. Security-headers middleware (HSTS/CSP/etc). DONE:
   `livery_security_headers` (nosniff, frame options, referrer policy,
   HSTS on TLS, opt-in CSP). See `docs/guides/set-security-headers.md`.
7. Rate limiting / throttling. DONE: `livery_ratelimit` (per-key token
   bucket via `limiter/2,3`, keyed by bearer token by default, `429` +
   `RateLimit-*`/`Retry-After`), backed by the supervised
   `livery_ratelimit_store` ETS table. See
   `docs/guides/rate-limit-requests.md`.
8. HTTP caching primitives (ETag, conditional GET, Cache-Control).
   DONE: `livery_etag` (auto strong/weak ETag, `If-None-Match` -> 304,
   handler override) plus `livery_resp:with_etag/2` and
   `with_cache_control/2`. See `docs/guides/http-caching.md`.
9. Static-directory serving with ETag/MIME. DONE: `livery_static`
   (`handler/1,2` mounted on a `*path` wildcard route; MIME by extension,
   weak ETag + conditional GET, Range, directory index, strict path
   confinement). See `docs/guides/serve-static-files.md`.
10. Health/readiness endpoints + Prometheus `/metrics`.

## Benchmarking: H3 needs an external client

The in-VM bench harness understates H3. Findings (loopback, 14
schedulers):

- H3 throughput saturates at ~18k req/s by 16 connections and stays
  flat to 200 connections; only latency grows (throughput =
  concurrency / latency). H1 scales to ~74k.
- It is not CPU-bound: aggregate scheduler busy is ~32% (about 10 of
  14 cores idle) during the H3 run.
- It is not the server UDP-listener pool: `pool_size` 1 through 8
  makes no difference to the in-VM number.

The ceiling is the in-VM QUIC round trip, since the harness runs the
QUIC client and server in the same BEAM VM and the client stack is
on the critical path. To measure H3 server throughput, drive Livery
from an external native QUIC client (quiche-client, h2load with
HTTP/3, or curl --http3) on a separate process or host. Profiling
already showed Livery's H3 adapter is not the bottleneck.

`livery_h3:start/1` now accepts `pool_size` (forwarded to
`quic_h3`); `>1` enables SO_REUSEPORT so production H3 can use more
than one UDP reader process. It does not change the in-VM benchmark,
but helps real external traffic spread across cores.

## Upstream: optimize HTTP/3 header validation in `erlang_quic`

Profiling an H3 request/response loop (`livery_bench:profile(h3, 100)`,
fprof, all processes) shows header validation as a top own-time hot
path, comparable to the AEAD crypto and well above anything in
Livery's adapter:

- `quic_h3_connection:validate_field_name_chars/2` (~6,800 calls per
  100 requests, ~13% own time)
- `quic_h3_connection:validate_field_value_chars/2` (~5,500 calls,
  ~13% own time)

The cost is structural: every header (pseudo-headers and constant
headers included) is validated byte by byte, and each byte makes a
separate function call to a guard-based predicate
(`is_tchar_lowercase/1`, `is_field_value_char/1`). That is two
function calls per character.

Where it lives: `src/h3/quic_h3_connection.erl`, around lines
2626 to 2696 (`validate_field/1` -> `validate_field_name/1` /
`validate_field_value/2` -> the per-char loops).

Goal: cut the per-character function-call overhead without changing
validation semantics (RFC 9114 section 4.3 and RFC 9110 field rules:
lowercase token chars for names, no control chars in values).

Suggested approaches (open to better):

1. Skip validation for QPACK static-table entries. They are constant
   and valid by construction; flag them as pre-validated at decode
   time so `validate_field` only runs on literal and dynamic entries.
   This likely removes most calls for typical traffic.
2. Replace the per-byte predicate call with a 256-entry byte
   classification table (a `binary()` checked with `binary:at/2`, or a
   tuple via `element/2`) consulted inline in the recursion, so each
   byte is a constant-time lookup instead of a function call.
3. Optionally validate the whole field in one pass and only fall back
   to per-byte scanning to locate the offending char on failure
   (failure is the rare path).

Acceptance criteria:

1. Validation behaviour is unchanged: existing H3 header tests pass,
   plus cases for an invalid name char, an invalid value char, an
   empty name, and a bare `:`.
2. A profile of the same request loop shows `validate_field_*`
   materially reduced, ideally out of the top hot path.
3. No new dependencies; malformed headers still reject with
   `throw({header_error, ...})`.

When done, cut a tagged hex release and bump `quic` in `rebar.config`.

Context: Livery's H3 adapter and dispatch are not the bottleneck. The
remaining H3 cost is inherent to userspace QUIC (AEAD, the connection
state machine, per-packet processing, UDP syscalls). The benchmark
also runs the QUIC client and server in one VM, so the H3 figure is
pessimistic versus an external client.
