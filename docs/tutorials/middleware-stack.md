# Tutorial: Compose a middleware stack

Build a middleware stack that adds a request id, logs every
request, caps the body size, and catches handler crashes. About
10 minutes.

## 1. Start from a handler that crashes

```erlang
-module(crashy).
-export([go/1]).

go(_Req) -> error(boom).
```

```erlang
?assertExit({boom, _},
            livery_test_adapter:run([], fun crashy:go/1, #{})).
```

Without middleware, the crash propagates. That is intentional: the
per-request process (`livery_req_proc`) maps it to a 500 when a
real adapter spawns the worker. In a unit test where you call the
handler directly, you want a wrapping middleware to do the same.

## 2. Catch the crash

```erlang
Wrap = livery_middleware:wrap(fun (_Class, _Reason, _Stack) ->
    livery_resp:text(500, <<"internal error">>)
end),

Cap = livery_test_adapter:run([Wrap], fun crashy:go/1, #{}),
?assertEqual(500, livery_test_adapter:status(Cap)).
```

`livery_middleware:wrap/1` is sugar for `try Next(Req) catch ...
end`. It belongs near the top of the stack.

## 3. Stack: outside-in

The first entry in the stack list is outermost. It sees the
request first and the response last.

```erlang
Stack = [
    {livery_request_id, undefined},
    livery_middleware:wrap(fun crashy:errors_to_resp/3),
    {livery_access_log, #{}},
    {livery_body_limit, #{max => 1_048_576}}
].
```

- `livery_request_id` runs first so error responses still carry an id.
- `wrap` runs second so it catches anything below.
- `livery_access_log` runs after that so it observes the final status.
- `livery_body_limit` runs closer to the handler so other middlewares
  see the request even if the body would be rejected.

## 4. Verify ordering with metadata

Want proof that middleware sees the request before the handler?

```erlang
Stack = [
    livery_middleware:before(fun(R) -> livery_req:set_meta(seen, yes, R) end)
],
Handler = fun(R) ->
    Tag = livery_req:meta(seen, R),
    livery_resp:text(200, atom_to_binary(Tag))
end,
Cap = livery_test_adapter:run(Stack, Handler, #{}),
?assertEqual(<<"yes">>, livery_test_adapter:body(Cap)).
```

`livery_middleware:before/1` lifts a request transformer. There is
also `after_response/1` for response transformers.

## 5. Short-circuit

A middleware that returns a response without calling `Next` skips
the rest of the pipeline including the handler.

```erlang
NotFound = fun(_Req, _Next) -> livery_resp:text(404, <<>>) end,
Cap = livery_test_adapter:run([NotFound], fun (_) -> error(unreached) end, #{}),
?assertEqual(404, livery_test_adapter:status(Cap)).
```

This is how auth, rate limiting, and CORS preflight middlewares
work.

## Next steps

- Reference: `livery_middleware`
- Built-in modules: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Recipe: [Write a custom middleware](../guides/custom-middleware.md)
