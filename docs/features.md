# Follow-ups

Tracked work that is not yet scheduled. Upstream items link to the
sibling library that owns the change.

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
