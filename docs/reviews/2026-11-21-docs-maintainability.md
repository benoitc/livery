# Livery documentation and maintainability plan

Review of `main` at 96be7aa (after 0.14.1, with #122 and #123 merged; #124
open), made on 2026-11-21 before the next release. It is the first review
of Livery; the next one updates this file. Nothing in `src/` was changed.

## Update before the release after 0.15.0

Rechecked on `main` at e769309, the same day. Only #126 merged since
0.15.0: h1 0.13.1, barrel_mcp 4.8.0 in the test and check profiles, a
stricter MCP cancel test, and three lines of the MCP guide. Nothing under
`src/` changed, so every measurement below still holds (98 modules,
about 15,900 lines).

Fixed in 0.15.0, as the maintainer chose:

- the docs index lists all 54 guides (it listed 33);
- every one of the 98 modules is in a sidebar group (63 were).

Both still hold: no guide or module was added since.

Still open, unchanged: the authentication and outbound client concept
pages, the code map and "If you want to..." pages, `docs/features.md`
and `docs/design.md`, the `livery_inet` module doc, and the five
questions in section 13. Nothing new was found.

Recommendation for this release: nothing needs fixing first.

## What it found

Livery is in good shape for a human reader. The code is split into small
modules with one job each (98 modules, about 15,900 lines without comments;
the largest is 520), every module but one has a module doc, and the user
docs follow Diataxis with 54 guides, 6 tutorials and 7 concept pages, all
checked by `livery_docs_SUITE`.

The gaps are in navigation and in the contributor side:

1. The docs index (`docs/README.md`) lists 33 of the 54 guides. The 21
   missing ones include every authentication guide, so a reader of the
   index cannot find that Livery verifies JWTs, signs users in with OpenID
   Connect or passkeys, or binds tokens.
2. The ex_doc sidebar groups 63 of the 98 modules. The other 35 land in an
   ungrouped list, among them `livery_client` and its 17 layers,
   `livery_service` and the three adapters, so the reference hides the
   outbound client and the runtime.
3. Authentication (24 modules, 15 guides) and the outbound client (18
   modules) have no concept page. Each guide explains one task, but nothing
   says how the pieces fit, which ones are middleware and which are
   helpers, or which store to plug in where.
4. The best map of the code for a contributor is in `AGENTS.md`, written
   for agents. `CONTRIBUTING.md` says how to set up and what CI checks, but
   not where to go to change a behaviour, or which test covers a module:
   48 modules have no test file named after them and are covered by a
   subsystem suite instead (for example `livery_auth_jose` by
   `livery_auth_tests`).
5. `docs/features.md` is titled "Follow-ups" but 15 of its items are done;
   3 are open. `docs/design.md` (423 lines) repeats much of `overview.md`,
   `what-is-livery.md` and `concepts/architecture.md`.

No module needs splitting before the release. The one function worth a
look is `livery:emit_body/7`, 132 lines over eight clauses.

## Recommendation for 0.15.0

Fix before releasing, because hexdocs is published with the release:

- add the 21 missing guides to `docs/README.md`;
- group the 35 ungrouped modules in the ex_doc sidebar;
- replace the stale "Reference" module list in `docs/README.md` with the
  sidebar groups.

Everything else can wait for the following release.

## 1. Recommended structure

A reader goes through four layers. Livery already has the first two for
users; the plan completes the index and adds the contributor layers.

1. **Orientation**: `README.md` (what it is, install, hello world),
   `docs/what-is-livery.md` (no code), `docs/overview.md` (when to use it,
   principles), `docs/quickstart.md`.
2. **Concepts**: `docs/concepts/` (architecture, request and response,
   middleware, routing, lifecycle, adapters, streaming), plus two new
   pages: authentication and the outbound client.
3. **Developer guide**: a new `docs/contributing/code-map.md` that maps
   each concept to its directory, modules and tests.
4. **Contributor workflows**: new "If you want to..." pages under
   `docs/contributing/`, linked from `CONTRIBUTING.md`.

## 2. Starting point

`docs/README.md` stays the starting point for users. Give it a second
table, "If you want to change Livery", that points to the code map and the
workflows, so a contributor has a door too. `CONTRIBUTING.md` links there.

## 3. Audience of each document

| Document | Reader | After reading, they know |
|---|---|---|
| `README.md` | someone choosing a framework | what Livery is and how a service looks |
| `docs/what-is-livery.md` | a non-developer | the problem it solves and where it stands |
| `docs/overview.md` | a developer deciding | when to use it and how it differs from Cowboy |
| `docs/quickstart.md`, tutorials | a new user | how to build and test a service |
| guides | a user with one task | how to do that task |
| concepts | a user or contributor | why it works this way |
| `docs/design.md` | the maintainer, reviewers | the founding design and the road to 1.0 |
| `AGENTS.md` | coding agents | the rules and the map, terse |
| `CONTRIBUTING.md` | a contributor | how to work, test and send a change |
| code map, workflows (new) | a contributor | where to change what, and how to check it |

## 4. Existing documents

| Document | Action | Reason |
|---|---|---|
| `docs/README.md` | rewrite index | 21 guides missing; "Reference" lists 13 modules of 98; "Project state" points to `design.md` |
| `docs/features.md` | rewrite | keep the 3 open items (external H3 benchmark client, H3 header validation upstream, Front-Channel Logout); move the done ones to the CHANGELOG history, which already has them |
| `docs/design.md` | keep, trim (question 1) | sections 1 to 3 and 5 repeat `overview.md` and `concepts/architecture.md`; "Toward 1.0" is the only place the 1.0 criteria live |
| `docs/overview.md`, `docs/what-is-livery.md` | keep | distinct readers |
| `docs/concepts/architecture.md` | keep, extend | its diagram stops at REST, MCP and streaming; add auth and the client as layers, link the two new concept pages |
| `docs/concepts/adapters.md` | keep | its outbound section becomes a link to the client concept page |
| guides | keep | one task each, task-oriented, checked by the docs suite |
| `docs/ecosystem.md` | keep, link | not in the index; the index repeats its content |
| `CONTRIBUTING.md` | keep, extend | add a pointer to the code map and the workflows, and the module-to-test rule |
| `AGENTS.md` | keep | agent-facing; the code map becomes the human version of its map |

## 5. Missing documents

**`docs/concepts/authentication.md`**. Intent: show how the auth pieces fit.
Reader: a user adding auth, a contributor touching `src/auth/`. After it
they know the three families (verify a caller: bearer, JWT, introspection,
DPoP, mTLS; sign a user in: OIDC login, sessions, passkeys, TOTP; call out
with credentials: OAuth client, token store), which are middleware and
which are helpers, which stores are per node and how to share them, and
where the spec table and Known deviations are. Points to: the 15 auth
guides, `SECURITY.md`. Detail: one screen of prose and a diagram, no
options lists.

**`docs/concepts/outbound-client.md`**. Intent: explain the client as the
middleware model turned around. Reader: a user stacking layers, a
contributor adding one. After it they know the layer order, which layers
keep state and where (circuit, balance, cookie, token stores), what the
fixed terminal step does and why it cannot be reordered, and how an
adapter plugs in. Points to: the three client guides, the call-a-service
tutorial. Detail: short, with one layer diagram.

**`docs/contributing/code-map.md`**. Intent: "where does this live". Reader:
a contributor. A table per area (runtime, adapters, worker and translator,
router and middleware, response emit, client, auth, codecs, MCP and A2A,
static files): directory, modules, entry point, tests, what to read first.
Detail: tables, two lines of prose per area.

**`docs/contributing/` workflows**: see section 11.

## 6. Concepts that need their own explanation

- **The translator and the worker**: two processes per request, and why
  (`livery_translator`, `livery_req_proc`). `concepts/architecture.md`
  and `request-lifecycle.md` mention them; a contributor changing the body
  reader or disconnect handling needs one page that says who owns what.
- **Response started**: from #123, a crash after the first byte resets
  the stream instead of answering 500. One paragraph in
  `request-lifecycle.md` and the handler-errors guide exist; the code map
  should name `livery_req_proc:response_started/0` as the place.
- **Taken over**: the `taken_over` body that ends `emit/3` for WebSocket,
  WebTransport, MCP and A2A. Named in `AGENTS.md`, missing from concepts.
- **Capabilities and optional callbacks**: how a protocol difference
  reaches a handler without the handler knowing the protocol (founding
  rule 3). `concepts/adapters.md` covers it in part.
- **Stores**: the ETS tables owned under `livery_sup` (rate limit, DPoP,
  session, client stores) and the behaviours that replace them.

## 7. Navigation guide

| You want to understand or change | Directory and modules | Tests |
|---|---|---|
| starting and stopping a service | `src/livery_service.erl`, `livery.erl` (service lifecycle), `livery_drain.erl`, `livery_service_guard.erl` | `livery_service_SUITE`, `livery_drain_tests` |
| one protocol on the wire | `src/livery_h1.erl`, `livery_h2.erl`, `livery_h3.erl`, `livery_h1h2.erl` | `livery_h1_SUITE`, `livery_h2_SUITE`, `livery_h3_SUITE`, `livery_alpn_SUITE` |
| behaviour every protocol must share | the above | `livery_parity_SUITE`, `livery_e2e_SUITE` |
| the request worker, body and disconnect | `livery_translator.erl`, `livery_req_proc.erl`, `livery_req_sup.erl`, `livery_body.erl`, `livery_disconnect.erl` | `livery_translator_tests`, `livery_req_proc_tests`, `livery_body_tests`, `livery_disconnect_tests` |
| routing | `livery_router.erl` | `livery_router_tests`, parity |
| writing the response | `livery.erl` (dispatch and emit, file, SSE), `livery_resp.erl` | `livery_resp_tests`, `livery_tests`, parity |
| a middleware | `src/middleware/` | `livery_builtin_middleware_tests`, `livery_middleware_tests`, one `*_tests` per larger middleware |
| content coding | `src/codec/` | `livery_compress_tests` |
| outbound HTTP | `src/client/` | `livery_client_SUITE`, `livery_client_*_tests`, `livery_client_balance_SUITE`, `livery_client_cookie_SUITE` |
| authentication | `src/auth/` | `livery_auth_*_tests`, `livery_auth_outbound_SUITE`, `livery_mtls_SUITE` |
| MCP and A2A | `livery_mcp.erl`, `livery_a2a.erl`, `livery_engine_bridge.erl` | `livery_mcp_SUITE`, `livery_a2a_SUITE`, `livery_a2a_tests` |
| WebSocket and WebTransport | `livery_ws*.erl`, `livery_wt.erl` | `livery_ws_SUITE`, `livery_wt_SUITE`, `livery_upgrade_tests` |
| the docs themselves | `docs/` | `livery_docs_SUITE` |

## 8. Modules that need better documentation

| Module | Role | Gap |
|---|---|---|
| `livery_inet` | utility | the only module without a module doc |
| `livery_engine_bridge` | integration | its doc says what it does, not that it is the one place MCP and A2A share limits and the response-started mark |
| `livery_service_guard` | core | when it runs and what it protects against (listeners left behind by a dead service, 0.14.1) |
| `src/auth/` as a whole | public | per-module docs are good; the subsystem view is missing (section 5) |
| `src/client/` as a whole | public | same |

## 9. Size and complexity

Measured on 98 modules in `src/` (lines without comments or blank lines):

| Module | Lines | Functions | Exports | Note |
|---|---|---|---|---|
| `livery_multipart` | 520 | 44 | 7 | one parser, coherent |
| `livery` | 511 | 37 | 11 | five sections: service lifecycle, router dispatch, dispatch and emit, file emission, SSE framing |
| `livery_resp` | 504 | 38 | 38 | constructors; a wide but flat surface |
| `livery_auth_login` | 493 | 49 | 6 | the OIDC login flow, coherent |
| `livery_h1`, `livery_h3`, `livery_h2` | 428, 419, 398 | about 30 | 12 to 14 | three adapters of the same shape |
| `livery_req` | 302 | 39 | 39 | accessors |
| `livery_client` | 345 | 48 | 36 | the client API and its fixed terminal step |

Directories: `src/` 36 modules, `src/auth/` 24, `src/client/` 18,
`src/middleware/` 15, `src/codec/` 5.

`livery` is the one module mixing responsibilities: the public facade
(`start_service/1`, `drain/1`) and the emit engine. They are separate
sections and each is short. A future split (emit into `livery_emit`) would
make `livery` the facade only; primary problem **module organisation**,
not urgent, affects `livery_req_proc`, the engine bridge and every module
that calls `livery:emit/3`. Question 3.

## 10. Functions worth reviewing

- `livery:emit_body/7` (`src/livery.erl`, about line 228): 132 lines over
  eight clauses, one per body variant. Each clause is readable; the `file`
  clause nests three `case` levels. Moving file emission into its own
  function would bring the longest clause under 30 lines. Primary problem
  **code complexity**, low priority.
- `livery_auth_session:login` (47 lines) and `livery_router:insert` (42):
  long but linear.

## 11. "If you want to..." guides

Each one names the files to open, the test to add and the check that
proves it.

- **Add a middleware**: `src/middleware/`, the `call/3` contract in
  `livery_middleware`, `livery_timeout` as the model for running `Next`
  elsewhere, a test in `livery_builtin_middleware_tests` or its own file,
  a guide under `docs/guides/` registered in the ex_doc extras.
- **Change how a response is written**: `livery:emit/3`, the adapter
  callbacks in `livery_adapter`, a parity case, then the per-protocol
  suites.
- **Add an adapter**: `livery_adapter`, `livery_test_adapter` as the
  smallest example, `livery_translator` for the request side, the parity
  suite as the acceptance test.
- **Add an auth method**: `src/auth/`, the spec table and Known deviations
  in `AGENTS.md`, `SECURITY.md` for what counts as a security issue, the
  auth concept page.
- **Add a client layer**: `src/client/`, the layer contract in
  `livery_client`, why the terminal step stays last.
- **Debug a request end to end**: listener, translator, worker, middleware,
  handler, emit, adapter; which log or trace to turn on at each step.
- **Bump a wire library**: what to check in its changelog, the profiles to
  upgrade, the `vsn` to confirm in `_build/<profile>/lib`, the suites that
  catch a change.

## 12. Diagrams and examples

- The architecture diagram, redrawn with auth and the client as layers.
- One sequence for a request: listener, translator, worker, emit, with the
  body and disconnect messages between translator and worker.
- One stack for the client: layers, terminal step, adapter.
- In the auth concept page, the three families and their stores.

## 13. Questions for the maintainer

1. Is `docs/design.md` the announcement document, to keep as written
   (then mark it dated), or a living design page (then trim what the
   concepts now say)?
2. Should done items leave `docs/features.md`, or do you want it to stay a
   record of what was audited?
3. Is a future `livery_emit` split welcome, or do you want `livery` to
   keep both the facade and the emit engine?
4. Should contributor pages live under `docs/contributing/` (published on
   hexdocs) or stay out of the published docs?
5. The `pipeline` option of `livery_h1` now has no effect (#124). Keep it
   for compatibility until 1.0, or remove it in the next minor?

## 14. Order

1. Before the release: the docs index and the ex_doc groups (section 4,
   first row, and the sidebar), a few hours.
2. The code map, since the workflows and concept pages link to it.
3. The authentication and outbound client concept pages.
4. `docs/features.md` and `docs/design.md`, once questions 1 and 2 are
   answered.
5. The "If you want to..." guides, starting with middleware, adapter and
   auth.
6. Diagrams.
7. The `emit_body/7` and `livery_emit` items, only if question 3 says yes.
