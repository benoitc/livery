# Contributing

This page is for people changing Livery itself. For using it, start with
the [Quickstart](docs/quickstart.md) and the [guides](docs/README.md). For
finding your way around the source, read [AGENTS.md](AGENTS.md#architecture)
and [docs/design.md](docs/design.md).

## Write for the person who reads it

Every issue, pull request and comment is read by a person. Make it easy for
them.

- Read what you send before you send it. You are responsible for every line,
  whether you wrote it or a tool did.
- Use plain English and short sentences. Say what happens, what you
  expected, and how to reproduce it. Explain any term a reader may not know.
- Don't inflate it. No buzzwords, no severity scores, CVSS or CWE labels, no
  "critical" for a bug, no long generated write-ups. If it takes a page to
  explain, cut it down until it doesn't.
- A bug report gives: the Livery and OTP versions, the protocol (HTTP/1.1,
  HTTP/2 or HTTP/3, over TLS or not), the listener options and middleware
  stack you set, the client you used, a handler small enough to paste, what
  you got and what you expected.
- A pull request says what was wrong and why it matters, the fix in a few
  lines, and any breaking change. Link the issue. Don't walk through the diff
  file by file; the reviewer reads the code.
- A fix comes with a test that fails without it.

AI tools are fine to use. Before you open anything, you must have read the
change, run the tests, and be able to answer questions about it yourself.

Maintainers read every issue and pull request before acting on it. We close
without further review:

- text we cannot understand after one request to clarify;
- descriptions that don't match the code or the reproduction;
- reports that cannot be reproduced;
- submissions opened by an automated agent that no person has read.

## Security issues and bugs

Livery implements HTTP semantics, cookies, CORS, the auth flows and the
other specifications listed in
[AGENTS.md](AGENTS.md#specifications), on top of wire libraries that do
the framing.

When the fix is to make Livery do what one of these specifications says,
or to enforce a limit one of its options defines, it is a bug, not a
security issue. That includes reports described as denial of service,
resource exhaustion or a remote crash, when they come from:

- a request accepted, rejected or answered differently from the
  specification (status, headers, `Vary`, conditional requests, ranges,
  content coding, multipart, SSE framing);
- a limit Livery offers not holding: `max_body`, `livery_body_limit`,
  `livery_timeout`, `livery_ratelimit`, `livery_concurrency`, the H1
  slow-client guards;
- behaviour that differs between HTTP/1.1, HTTP/2 and HTTP/3 where the
  parity suite says it should not.

Some differences from a specification are deliberate. They are listed,
with the reason, under
[Known deviations](AGENTS.md#known-deviations); a report about one of
them is answered with that reason.

Report these as a normal bug, in public. Cite the specification section or
the option. The fix goes in a public pull request and in the CHANGELOG under
Fixed. We don't publish advisories or request CVEs for them, and advisories
filed for them are closed with a link to the fix.

Only problems that let someone past what the configuration protects go
through [SECURITY.md](SECURITY.md): code execution, a request accepted
without the authentication or authorization the configuration asks for
(tokens, sessions, OIDC, client certificates), one client's data reaching
another, a file served outside the static root, CORS granting an origin
the configuration does not allow, the client leaking credentials to
another host, or Livery weakening TLS below what the configuration asks
for.

### Where to report

Livery never parses the wire itself. A problem in framing, header
compression, flow control or the TLS handshake belongs to the library that
does it, under that project's own policy:

| Area | Project |
|---|---|
| HTTP/1.1 | [erlang_h1](https://github.com/benoitc/erlang_h1) |
| HTTP/2 | [erlang_h2](https://github.com/benoitc/erlang_h2) |
| QUIC, HTTP/3, QPACK | [erlang_quic](https://github.com/benoitc/erlang_quic) |
| WebSocket | [erlang_ws](https://github.com/benoitc/erlang_ws) |
| WebTransport | [erlang-webtransport](https://github.com/benoitc/erlang-webtransport) |
| Outbound HTTP client transport | [hackney](https://github.com/benoitc/hackney) |
| Metrics and tracing | [instrument](https://github.com/benoitc/instrument) |
| MCP, A2A protocol engines | [barrel_mcp](https://github.com/barrel-platform/barrel_mcp), [barrel_a2a](https://github.com/barrel-platform/barrel_a2a) |

If you are not sure which side a problem is on, report it here and we will
move it.

## Set up

You need Erlang/OTP 27 or later, rebar3, and CMake with a C compiler for
the `instrument` NIF.

```bash
git clone https://github.com/benoitc/livery.git
cd livery
rebar3 compile
```

The test certificates are in `test/certs/`; nothing to generate.

To work on Livery and a wire library together, link the sibling checkout
under `_checkouts/` (it is gitignored). rebar3 then builds the local copy
instead of the hex package:

```bash
mkdir -p _checkouts
ln -s ../../erlang_h2 _checkouts/h2
```

A fix that belongs in a wire library goes upstream first. Keep the
adapters thin.

## Before you commit

Run what CI runs. These are the checks that gate a pull request:

```bash
rebar3 fmt                 # format first, then check the rest
rebar3 compile             # warnings are errors
rebar3 lint
rebar3 as check xref
rebar3 as check dialyzer
rebar3 eunit
rebar3 ct
```

## Tests

- `test/*_tests.erl` are EUnit tests, run by `rebar3 eunit`.
- `test/*_SUITE.erl` are Common Test suites, run one at a time with
  `rebar3 ct --suite=test/livery_h2_SUITE`.
- `livery_parity_SUITE` runs the same requests through every adapter and
  compares what a client sees. A change in what a handler or client observes
  goes there, so the protocols cannot drift apart.
- `livery_e2e_SUITE` runs a full journey over HTTP/1.1, HTTP/2 and HTTP/3.
  A change to the service runtime, Alt-Svc or drain is checked across the
  whole chain, not one adapter.

A test must fail for one reason. A denial test that also passes when the
call crashes, or a test that asserts a value it computed itself, is worse
than no test because it reads as coverage.

## What CI enforces

| Job | What it proves |
|-----|----------------|
| erlfmt, Elvis lint, XRef, Dialyzer | Formatting, lint rules, cross references and types. The other jobs wait for these. |
| Build OTP 28 | Compiles on Ubuntu x86-64 and arm64, and macOS 15 |
| EUnit | `rebar3 eunit` on Ubuntu and macOS 15 |
| Common Test | `rebar3 ct` on Ubuntu and macOS 15 |

## Documentation

`docs/` follows Diataxis: tutorials, how-to guides and concepts.
`livery_docs_SUITE` compiles every module snippet in the docs and checks
that each `livery_*` call they show is exported at that arity, so a
renamed or removed function fails with the docs that use it. Fix them in
the same change.

Write guides in the task-oriented style the existing ones use: say what
the thing is, when you need it, then show the steps with short notes
between code blocks. Register a new page in the `ex_doc` extras in
`rebar.config`.

## Pull requests

Branch from `main` using the prefix that fits: `fix/`, `feat/`, `perf/`,
`refactor/`, `docs/`, `test/` or `chore/`.

Write the commit subject in the imperative, describing what the code now
does. Keep the body for the reason when it is not obvious. Do not add
generated-by or co-authored-by trailers.

A change to how Livery reads or answers requests (routing, headers,
caching, ranges, content coding, cookies, CORS, auth) passes three checks
before it is opened: it follows the specification section it cites, that
specification is the current one, and it stays safe against a hostile
client, with every per-client resource bounded.

Say what the change is for and how it works. Skip the test inventory: CI
reports that. If the change touches the public API, show it in a short
code block.

## Releases

The version lives in `src/livery.app.src`. A release is a commit on `main`
named `Release X.Y.Z` that bumps it and promotes the CHANGELOG
`[Unreleased]` section, then a `vX.Y.Z` tag and a GitHub release carrying
that CHANGELOG section. The maintainer publishes to hex.
