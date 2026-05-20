# The middleware pipeline

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
