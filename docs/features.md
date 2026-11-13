# Follow-ups

Tracked work that is not yet scheduled. Upstream items link to the
sibling library that owns the change.

## Framework-gap backlog (from the audit)

Things web and AI frameworks usually offer and Livery lacked, in
priority order. All 10 items are done.

1. Cancel on client disconnect. DONE: `livery_req:on_disconnect/2`
   plus the `{livery_disconnect, _, _}` message, delivered across
   H1/H2/H3 by the per-stream translator (which monitors the
   connection). See `docs/guides/cancel-on-disconnect.md`.
2. CORS middleware. DONE: `livery_cors` (answers preflight requests
   itself; allowed origins as a list or a function; credentials,
   expose, max-age, and a `Vary` header that keeps caches correct). See `docs/guides/enable-cors.md`.
3. Response compression with Accept-Encoding. DONE (gzip + deflate):
   `livery_compress` negotiates over the `livery_codec` registry and
   compresses full + chunked bodies; `livery_codec_gzip` and
   `livery_codec_deflate` are built in over OTP `zlib`. See
   `docs/guides/compress-responses.md`. More codecs come as separate
   applications (separate PRs, linked against system libraries):
   `livery_brotli` (NIF, `br`) and `livery_zstd` (cmake NIF, `zstd`)
   implement the same behaviour and register themselves with
   `livery_codec:register/1`.
4. Multipart / form-data body parsing (uploads, multimodal). DONE:
   `livery_multipart` (a streaming parser you pull parts from, plus
   `read_all`; it buffers only a bounded amount and returns the filename
   exactly as sent) and `livery_ext:read_form/1,2` (reads urlencoded
   forms as a stream). See `docs/guides/handle-file-uploads.md` and
   `docs/guides/parse-form-bodies.md`.
5. Concurrency limit / load-shedding middleware (admission control).
   DONE: `livery_concurrency` (`limiter/1,2` builds one over a
   lock-free `atomics` counter; above the limit it answers `503` at
   once, with an optional Retry-After). See `docs/guides/limit-concurrency.md`.
6. Security-headers middleware (HSTS/CSP/etc). DONE:
   `livery_security_headers` (nosniff, frame options, referrer policy,
   HSTS on TLS, opt-in CSP). See `docs/guides/set-security-headers.md`.
7. Rate limiting / throttling. DONE: `livery_ratelimit` (per-key token
   bucket via `limiter/2,3`, keyed by bearer token by default, `429` +
   `RateLimit-*`/`Retry-After`), backed by the supervised
   `livery_ratelimit_store` ETS table. See
   `docs/guides/rate-limit-requests.md`.
8. HTTP caching primitives (ETag, conditional GET, Cache-Control).
   DONE: `livery_etag` (computes a strong or weak ETag, answers
   `If-None-Match` with 304, and lets the handler set its own) plus `livery_resp:with_etag/2` and
   `with_cache_control/2`. See `docs/guides/http-caching.md`.
9. Static-directory serving with ETag/MIME. DONE: `livery_static`
   (`handler/1,2` mounted on a `*path` wildcard route; MIME by extension,
   weak ETag + conditional GET, Range, directory index, and never a
   file outside its root). See `docs/guides/serve-static-files.md`.
10. Health/readiness endpoints + Prometheus `/metrics`. DONE:
    `livery_health` (`live/0`, `ready/1` with named checks) and
    `livery_metrics` (`handler/0` rendering the `instrument` registry via
    `instrument_prometheus`). See `docs/guides/health-checks.md` and
    `docs/guides/export-metrics.md`.

## Server-side gaps (closed in 0.7.0)

1. Peer address on plain HTTP requests. DONE: `livery_req:peer/1` is
   set on H1 (via `h1:peername/1`, h1 0.8.0), H2, and H3;
   `peer_info/1` returns the real peer on every adapter. Previously
   only the WebSocket handoff carried it.
2. Interim (1xx) responses. DONE: `livery_req:inform/3` (primarily
   `103 Early Hints`), backed by the optional adapter callback
   `send_informational/3` and advertised via the `informational`
   capability. H1 (h1 0.8.0) and H2 send it; H3 sends it since
   quic 2.7.0. See `docs/guides/early-hints.md`.
3. Connection teardown on stop. DONE: h1 0.8.0 tracks accepted
   connections; `h1:stop_server/1` is synchronous and closes them, so
   `livery:stop_service/1` really cuts off kept-alive clients.
   `h1:stop_accepting/1` keeps them serving during `livery:drain/2`,
   which closes the idle ones at the end of the window.

WebSocket extras shipped alongside (ws 0.4.0): `max_frame_size` /
`max_message_size` and `compress` (permessage-deflate) on
`livery_ws:upgrade/3`, and the peer's close code delivered to
`ws_handler:terminate/2` as `{remote, Code, Reason}`.

## Benchmarking: H3 needs an external client

The bench harness runs inside the VM and makes H3 look slower than it
is. What we found (loopback, 14 schedulers):

- H3 throughput tops out at ~18k req/s by 16 connections and stays
  flat up to 200 connections; only latency grows (throughput =
  concurrency / latency). H1 goes up to ~74k.
- CPU is not the limit: the schedulers are busy ~32% of the time
  overall (about 10 of 14 cores idle) during the H3 run.
- Nor is the server's pool of UDP listeners: `pool_size` 1 through 8
  makes no difference to the in-VM number.

The limit is the QUIC round trip inside the VM: the harness runs the
QUIC client and server in the same BEAM VM, so the client's own work
adds to every request. To measure H3 server throughput, drive Livery
from an external native QUIC client (quiche-client, h2load with
HTTP/3, or curl --http3) on a separate process or host. Profiling
already showed Livery's H3 adapter is not the bottleneck.

`livery_h3:start/1` now accepts `pool_size` (forwarded to
`quic_h3`); `>1` enables SO_REUSEPORT so production H3 can use more
than one UDP reader process. It does not change the in-VM benchmark,
but helps real external traffic spread across cores.

## Upstream: optimize HTTP/3 header validation in `erlang_quic`

Profiling an H3 request/response loop (`livery_bench:profile(h3, 100)`,
fprof, all processes) puts header validation among the functions with
the most own time (time spent in the function itself), about as much
as the AEAD crypto and far more than anything in Livery's adapter:

- `quic_h3_connection:validate_field_name_chars/2` (~6,800 calls per
  100 requests, ~13% own time)
- `quic_h3_connection:validate_field_value_chars/2` (~5,500 calls,
  ~13% own time)

The cost comes from how the check is written: every header (pseudo-headers and constant
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
   clearly reduced, ideally no longer among the top entries.
3. No new dependencies; malformed headers still reject with
   `throw({header_error, ...})`.

When done, cut a tagged hex release and bump `quic` in `rebar.config`.

Context: Livery's H3 adapter and dispatch are not the bottleneck. The
remaining H3 cost comes with running QUIC in user space (AEAD, the
connection state machine, per-packet processing, UDP syscalls). The
benchmark also runs the QUIC client and server in one VM, so the H3
figure is lower than an external client would measure.

## Deferred response status: decide stream-vs-error at the first byte

DONE: `livery_resp:stream_deferred/1`. `stream/3` / `sse/3` / `ndjson/3`
fix the status and headers at construction, so `livery:emit_body/6` writes
them before the producer runs. That rules out a common pattern with
asynchronous admission: "admit, then stream; if admission fails before
the first byte, reply with an error status". A request turned away for
lack of capacity could only send `200 OK` with an error inside the
stream, never a `429` with a JSON error body.

`stream_deferred(Resolver)` stores a `{deferred, Resolver}` body variant.
`Resolver` runs once in the worker, before any header write, and returns
one of:

    {stream, 100..599, headers(), producer()}
    {sse,    100..599, headers(), producer()}
    {ndjson, 100..599, headers(), producer()}
    {full,   100..599, headers(), iodata()}

`emit_body/6` converts the decision into a normal `#livery_resp{}` via the
existing `stream/3` / `sse/3` / `ndjson/3` / `new/3` constructors (reusing
the SSE/ndjson default headers and producer wrapping) and re-enters
`emit/3`, so no adapter contract changes. Headers added by wrapping
middleware (request id, security headers, CORS) merge under the decision's
headers via `resolve_deferred/2`; the decision wins when both set the same
header. An invalid decision crashes before any byte is sent, so the client
gets a plain 500. Tests:
`livery_tests:emit_deferred_*`, `livery_resp_tests:resolve_deferred_*`.

The original reproducer is `barrel_inference`'s `chat_busy_returns_429/1`
CT case (saturates a concurrency=1/depth=1 queue, asserts a racing request
reports `429`/`504`).

## HTTP QUERY method (RFC 10008)

DONE: QUERY works end to end, like any other method. The core already
handled any method (router dispatch, the 405 `Allow` header, body
reading, all three adapters), so the changes are the places where
QUERY had to be added on purpose: `livery_client:query/3`, QUERY in
the client's set of idempotent methods it retries and in the CORS
default allow-methods, and OpenAPI 3.2 output where a QUERY route
emits a `query` operation. Covered by the parity SUITE (`query_with_body`) across H1/H2/H3 and by a QUERY
search step in the e2e journey. See `docs/guides/query-method.md`.
