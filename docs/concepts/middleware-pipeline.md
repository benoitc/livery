# The middleware pipeline

This page explains what middleware is in Livery, the shape it takes, and
why it is a continuation over values rather than a mutable response you
write into. Read it when you have work to add that many routes share.
Middleware is the code that runs around your handlers: the work that does
not belong to one route but to many. A request id on every response, an
access log line, a body-size cap, an auth check, a CORS preflight, a
timeout. You write each one once and stack them.

A Livery middleware is a function over immutable values, in the
Tower/Axum style: it receives the request and a `Next` continuation, and
it *returns* a response. It can change the request before calling `Next`,
change the response after, not call `Next` at all, or wrap the call.
There is no shared response object to write into and remember to pass
on.

## When you want middleware (and when you do not)

**Use middleware when** the behaviour applies to a family of routes:
authentication, logging, rate limiting, CORS, compression, security
headers, request ids, deadlines. **Keep it in the handler when** the
logic is specific to one endpoint. **Put it on a route's `Meta`** when it
applies to only a few routes (see [Routing](routing.md)).

## A modern, value-based model

Livery's middleware is the **Tower/Axum** model, not the legacy
`(req, res, next)` one (rule 2 in [design.md](../design.md):
*"Middleware is a continuation"*).

**Legacy** (Express, Rack, Cowboy middlewares): a middleware gets a
mutable request *and* response object plus a `next` callback. You change
the response in place and remember to call `next()`. Nothing in the code
shows where control goes next, and every middleware changes the same
response.

```text
%% legacy shape - mutate-and-next
fun(Req, Res, Next) -> Res2 = set_header(Res, ...), Next(Req, Res2) end
```

**Livery** (continuation over immutable values): a middleware gets the
request and a `Next` continuation, and returns a response.

```erlang
%% Livery shape - continuation-passing, values in/out
call(Req, Next, State) ->
    Resp = Next(Req),                       %% run the rest of the stack
    livery_resp:with_header(<<"x-served-by">>, <<"livery">>, Resp).
```

Why it matters:

- **Immutable values.** `Req` and `Resp` are plain records, never a
  shared mutable handle: safe to pass between processes, easy to test.
- **Composition is a value.** `Next` *is* "the rest of the pipeline" as a
  function; wrapping it in `try`/`catch`, a timeout, or a span means
  calling it inside your own code.
- **Works with extractors.** Typed input comes from `livery_ext`
  (`json/1`, `query/2`, `bearer_token/1`), not from changing the request.

## Shape

A stack is an ordered list. Each entry is either:

- `{Module, State}` where `Module` implements the `livery_middleware`
  behaviour; or
- `fun(Req, Next) -> Resp` for one-off inline middleware.

`livery:dispatch/3` runs the stack against a request and a handler. The
first entry is outermost: it sees the request first and the response
last.

```text
Request  ──> M1 ──> M2 ──> M3 ──> Handler ──> M3 ──> M2 ──> M1 ──> Response
              ↑                                                       ↓
              └────── short-circuit returns response without ─────────┘
                       going deeper into the pipeline
```

## A complete middleware

A reusable middleware is a module implementing the one callback,
`call(Req, Next, State)`. `State` is whatever you configured the entry
with. This one rejects requests without a known API key, and lets the
others through:

```erlang
-module(my_api_key).
-behaviour(livery_middleware).

-export([call/3]).

call(Req, Next, #{keys := Keys}) ->
    case livery_req:header(<<"x-api-key">>, Req) of
        Key when is_binary(Key) ->
            case lists:member(Key, Keys) of
                true  -> Next(Req);                          %% pass through
                false -> livery_resp:text(403, <<"forbidden">>)  %% short-circuit
            end;
        undefined ->
            livery_resp:text(401, <<"missing api key">>)
    end.
```

## Wiring it in

A middleware does nothing until it is in a stack. Put it in the
service-wide stack to cover every route:

```erlang
Stack = [
    {livery_request_id, undefined},
    {livery_access_log, #{}},
    {my_api_key, #{keys => [<<"s3cret">>]}}
].
```

Or hang it off a single route's `Meta`, so it runs only there, nested
inside the service-wide stack:

```erlang
{<<"GET">>, <<"/admin">>, {admin, index},
 #{middleware => [{my_api_key, #{keys => [<<"s3cret">>]}}]}}
```

## The three shapes

1. **Pass-through.** Always calls `Next`; optionally transforms the
   request before or the response after. Examples: `livery_request_id`,
   `livery_access_log`.
2. **Short-circuit.** Returns a response without calling `Next`.
   Examples: auth failures, rate-limit hits, CORS preflight.
3. **Wrapper.** Calls `Next` inside `try`/`catch`, a monitor, or a
   spawned worker. Examples: `livery_middleware:wrap`, `livery_timeout`.

## Sugar constructors, and when to use them

For the common cases you do not need a whole module: turn a small
function into a stack entry.

```erlang
livery_middleware:before(fun(Req)  -> ... end)               %% request transform
livery_middleware:after_response(fun(Resp) -> ... end)       %% response transform
livery_middleware:wrap(fun(Class, Reason, Stack) -> ... end) %% try/catch
```

**Which one to use:**

| You need to ... | Use |
|---|---|
| tweak the request, always continue | `before/1` |
| tweak the response, always continue | `after_response/1` |
| recover from downstream crashes | `wrap/1` |
| short-circuit, hold config, or reuse it | a `call/3` module |

## Threading state to the handler

A middleware stores values for the handler with `livery_req:set_meta/3`;
the handler reads them with `livery_req:meta/2`. Typical values: the
authenticated user, a trace id, parsed form data. The handler may also
write `meta` for an `after_response` that runs after it.

## Ordering rules of thumb

| Position | Why |
|---|---|
| `livery_request_id` outermost | every response carries an id |
| error wrapper right below | catches everything, including auth and routing |
| `livery_access_log` after wrapper | sees the final status |
| `livery_body_limit` further in | bodies are checked once |
| `livery_timeout` further still | deadline covers body + handler |
| auth before business logic | handlers can assume `meta(user, _)` is set |
| handler last | a single function, not an entry in the stack |

## Performance

The pipeline is built per request as a chain of closures: each `Next` is
`fun(R) -> run(Rest, Handler, R) end`. The BEAM runs these cheaply: per
request, the pipeline costs a few function calls on top of the real
work. Keep stacks under about ten entries.

## Outbound: the same model, the other direction

The same model works for the requests your service sends. `livery_client`
is this pipeline turned around: you stack layers (timeout, retry,
circuit breaker, concurrency) around an HTTP request the same way you
stack middleware around a handler, and each layer is the same
`call(Request, Next, State)` shape, returning `{ok, Response} |
{error, _}`. See
[Make outbound HTTP requests](../guides/make-http-requests.md).

## See also

- Tutorial: [Compose a middleware stack](../tutorials/middleware-stack.md)
- Guide: [Write a custom middleware](../guides/custom-middleware.md)
- Guide: [Make outbound HTTP requests](../guides/make-http-requests.md)
- Reference: `livery_middleware`, `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
