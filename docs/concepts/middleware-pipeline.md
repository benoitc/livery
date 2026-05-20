# The middleware pipeline

## A modern, value-based model

Livery's middleware is the **Tower/Axum** model, not the legacy
`(req, res, next)` one. The difference is the core of the design
(principle #4 in [design.md](../design.md): *"Axum + Tower
ergonomics"*).

**Legacy** (Express, Rack, Cowboy middlewares): a middleware gets a
mutable request *and* response object and a `next` callback. You
mutate the response in place and remember to call `next()`; control
flow is implicit and the response is shared, mutable state.

```text
%% legacy shape — mutate-and-next
fun(Req, Res, Next) -> Res2 = set_header(Res, ...), Next(Req, Res2) end
```

**Livery** (Tower-style continuation over immutable values): a
middleware gets the request and a `Next` continuation, and *returns*
a response. There is no mutable response object; each stage either
returns a response, transforms one, or wraps the downstream call.

```erlang
%% Livery shape — continuation-passing, values in/out
call(Req, Next, State) ->
    Resp = Next(Req),                       %% run the rest of the stack
    livery_resp:with_header(<<"x-served-by">>, <<"livery">>, Resp).
```

Why it matters:

- **Immutable values.** `Req` and `Resp` are plain records, never a
  shared mutable handle — safe to pass between processes, trivial to
  test, no "did I forget to return the response" bugs.
- **Composition is a value.** `Next` *is* "the rest of the
  pipeline" as a function; wrapping it in `try`/`catch`, a timeout,
  or a span is just calling it inside your own code.
- **Pairs with extractors.** Like Axum, typed input comes from
  `livery_ext` (`json/1`, `query/2`, `bearer_token/1`), not from
  mutating the request as it flows.

### The alternative we did not take

The other modern model is the **interceptor chain** (Pedestal,
gRPC): the pipeline is a *data value* — a queue of
`#{enter, leave, error}` stages you can reorder, push/pop at
runtime, and pause/resume, with uniform error handling in a `leave`
phase. It is more introspectable and dynamic, at the cost of more
indirection and being less familiar to the Axum audience Livery
targets. Livery chose the Tower onion; reach for interceptors only
if you need to manipulate the chain mid-request.

## Shape

A middleware stack is an ordered list. Each entry is either:

- `{Module, State}` where `Module` implements the
  `livery_middleware` behaviour.
- `fun(Req, Next) -> Resp` for one-off inline middleware.

`livery:dispatch/3` runs the stack against a request and a handler.
The first entry in the list is outermost: it sees the request first
and the response last.

```
Request  ──> M1 ──> M2 ──> M3 ──> Handler ──> M3 ──> M2 ──> M1 ──> Response
              ↑                                                       ↓
              └────── short-circuit returns response without ─────────┘
                       going deeper into the pipeline
```

## The three shapes

1. **Pass-through.** Always calls `Next`. Optionally transforms the
   request before, the response after, or both. Examples:
   `livery_request_id`, `livery_access_log`.
2. **Short-circuit.** Returns a response without calling `Next`.
   Examples: auth failures, rate limit hits, CORS preflight.
3. **Wrapper.** Calls `Next` inside `try`/`catch`, a monitor, or a
   spawned worker. Examples: `livery_middleware:wrap`,
   `livery_timeout`.

## Sugar constructors

```erlang
livery_middleware:before(fun(Req)  -> ... end)        %% request transform
livery_middleware:after_response(fun(Resp) -> ... end) %% response transform
livery_middleware:wrap(fun(Class, Reason, Stack) -> ... end) %% try/catch
```

Each returns a stack entry that you can drop straight into the
list.

## State threading

Middleware can store values for the handler via
`livery_req:set_meta/3`. The handler reads them back with
`livery_req:meta/2`. Examples: authenticated user, trace id, parsed
form data.

The handler can also write to `meta` for downstream
`after_response` transformers.

## Ordering rules of thumb

| Position | Why |
|---|---|
| `livery_request_id` outermost | every response carries an id |
| Error wrapper just below | catches everything including auth and routing |
| `livery_access_log` after wrapper | sees the final status |
| `livery_body_limit` further in | bodies are checked once |
| `livery_timeout` further still | deadline applies to body + handler |
| auth before business logic | handlers can assume `meta(user, _)` is set |
| handler last | a single function, never explicit |

## Performance

The pipeline is built per request as a chain of closures: each
`Next` is `fun(R) -> run(Rest, Handler, R) end`. Modern BEAM
inlines these effectively; the per-request overhead is a few
function calls plus the actual work. Avoid stacks with hundreds of
entries; aim for under ten.

## See also

- Reference: `livery_middleware`
- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Tutorial: [Compose a middleware stack](../tutorials/middleware-stack.md)
