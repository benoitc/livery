---
name: livery-foundations
description: Check that a Livery change stays true to the framework's founding rules (values not handles, middleware as a continuation, protocol neutrality through capabilities, thin adapters over the wire libraries, the same model outbound) and to the AGENTS.md policies. Use it whenever you plan, implement or review a change under src/, before committing, before opening a pull request, and at the start of every phase of a multi-phase change, even when nobody mentions principles or architecture. Use it too when a change touches an adapter, a middleware, the request worker, the body reader, the outbound client, auth calling out over HTTP, or WebSocket and WebTransport upgrades.
---

# Livery foundations check

Livery was announced (0.2.0) with a clear shape: plain values, middleware as
a continuation, one handler set over H1, H2 and H3, thin adapters, and the
same model outbound. Code drifts from that shape one reasonable-looking
change at a time: a hard-coded adapter list here, a direct hackney call
there. This skill catches the drift while it is still one change.

Run it on a plan (before writing code) or on a diff (before committing).

## Steps

1. Run the mechanical checks. The script needs only bash and git, works
   from any directory inside the repository, and never modifies anything:

   ```
   .agents/skills/livery-foundations/scripts/check.sh            # whole tree
   .agents/skills/livery-foundations/scripts/check.sh main       # only what changed since main
   ```

   If you cannot run commands, do the same checks by reading: direct
   `hackney:` calls outside `src/client/`, per-adapter clauses outside the
   adapters, `set_stream_handler` without `flow_control => manual` in
   `livery_h2`/`livery_h3`, `spawn` in `src/middleware/`, the process
   dictionary outside `livery_middleware` and `livery_disconnect`, and
   em-dashes.

   Each line is a lead (`RULE file:line what`), not a verdict. Read the code
   at each lead and decide: drift, allowed exception (listed below), or a
   question for the maintainer.

2. Read the plan or the diff against the five rules below. The script only
   sees patterns; most drift is in design: where a responsibility lands,
   what a new function assumes, what a test does not cover.

3. Check the policies from `AGENTS.md` (end of this file).

4. Report with the template at the end. Every finding cites `file:line` or
   the plan step it concerns.

## The five rules

### R1 Values, not handles

`Req` and `Resp` are plain records (`include/livery.hrl`), never a shared
mutable handle, so they move between processes and are easy to test.

Ask: does the change add state that lives outside the values (a process
that owns per-request data, an ETS row keyed by request, the process
dictionary)? Could it be a field or `meta` on the value instead? Does a
handler or middleware now have to call something to "commit" a change?

Allowed: the emit-hook API in `livery_middleware` (`after_emit/1`,
`with_emit_hooks/1`) and the disconnect notifier in `livery_disconnect`
use the process dictionary by design. Shared node-wide stores (rate
limits, client stores, single-use store) are ETS tables owned by a process
under `livery_sup` and read directly by callers; that is shared policy
state, not per-request state.

### R2 Middleware is a continuation

`call(Req, Next, State) -> Resp`. `Next` is the rest of the pipeline as a
function, so wrapping it in a try/catch, a timeout or a span is just
calling it inside your own code.

Ask: does the middleware call `Next` at most once, in its own process? If
it runs `Next` somewhere else (another process, later), does it carry what
the pipeline keeps in the process dictionary (emit hooks, logger metadata,
trace context) and hand back what was registered there? Does it rely on
mutating anything the next layer sees other than the `Req` value it passes?

Drift looks like: `spawn` around `Next` without carrying context; a
middleware that reads state another middleware stored outside `Req`.

Allowed: `livery_timeout` runs `Next` in another process the right way
(`livery_middleware:capture_context/1` and `adopt_context/1`, hooks
handed back, body and disconnect messages passed on). Follow it if
you need the same.

### R3 Protocol neutrality

A handler never knows whether it is on H1, H2 or H3. The request and
response values are the same everywhere; protocol differences show up only
through `capabilities/1` or an optional adapter callback detected with
`erlang:function_exported/3` (as `livery_req:inform/3` does for
`send_informational/3`).

Ask: does code above the adapter boundary branch on the protocol or on an
adapter module name? Is a feature offered through a list of known adapters,
which a third-party adapter could never join? Does a behaviour visible to a
client differ between protocols, and if so, is there a case in
`test/livery_parity_SUITE.erl`?

Allowed: choosing which adapter to start (`livery:start_listener/2`,
`livery_service`). Response values carry the protocol-neutral meaning even
when the wire differs (a WebSocket upgrade is status 101 on every
protocol, although H2 and H3 send 200 to the extended CONNECT).

### R4 Thin adapters over the wire libraries

Framing, header compression, flow control, QUIC and TLS live in `h1`, `h2`,
`quic`, `ws` and `webtransport`. An adapter translates between the wire
library and Livery's values and messages, nothing more.

Ask: does the change parse, frame, buffer or pace anything the wire
library could do? Before writing code, check what the library already
offers (for example, manual receive flow control with `consume/3` in both
`h2` and `quic_h3`). Is a wire-level problem being worked around in an
adapter instead of being fixed upstream (`CONTRIBUTING.md`, "Where to
report")? Is the same adapter skeleton being copied a fourth time instead of
shared?

### R5 The same model outbound

`livery_client` is the middleware model turned around: layers around an
adapter. Outbound HTTP from anywhere in Livery (auth included) goes through
it, so timeouts, TLS settings, retries and origin rules apply once.

Ask: does the change call hackney (or any HTTP library) outside
`src/client/`? Is a client feature added as a layer, or hidden in the
terminal step? Does it work for streamed requests too, or only buffered
ones?

Allowed: the fixed terminal step in `livery_client:send/3` (the
credential-origin check and DPoP signing must apply to the final request,
whatever order the user stacks layers in).

## Policies from AGENTS.md

- A change to how Livery reads or answers requests cites the spec section,
  checked against the current spec, and is safe against a hostile client
  with every per-client resource bounded.
- An intentional deviation from a spec is listed in AGENTS.md "Known
  deviations" and in the module doc, with its reason.
- Limits are never relaxed to make a client pass.
- Spec bugs and security issues are told apart as AGENTS.md says; a
  security issue is not described or fixed in public.
- Every fix has a test that fails on `main`; parity cases for anything a
  client can observe.
- Docs and CHANGELOG in the same pull request; CHANGELOG in plain English.
- No em-dash anywhere; commits and pull requests carry no generated-by or
  co-authored-by trailers.

## Report template

```
## Foundations check: <plan or diff name>

Mechanical: <N> leads (<M> drift, <K> allowed, <Q> questions)

### Must fix
- [R3] src/livery_ws.erl:182 WebSocket support is a list of adapter
  modules; a third-party adapter can never offer it. Make accept_ws/4 an
  optional callback and detect it with function_exported.

### Questions for the maintainer
- [R5] ...

### Holds
- R1: <one line on why it holds, or "not touched">
- R2: ...
- R4: ...
- Policies: ...
```

Keep "Must fix" to real drift. If a finding is a trade-off the rules do not
settle, it is a question, not a must-fix.
