# How to catch handler errors

When a handler crashes (`error(badmatch)`, `throw(_)`, division by
zero, etc.) you want a controlled response instead of a propagating
exit. Wrap the rest of the stack with `livery_middleware:wrap/1` and
turn each class of failure into the response shape you want.

## Wrap the stack

```erlang
Stack = [
    {livery_request_id, undefined},
    livery_middleware:wrap(fun errors_to_resp/3),
    %% ... handler
].

errors_to_resp(throw, {validation, Why}, _Stack) ->
    livery_resp:text(400, Why);
errors_to_resp(error, {badkey, K}, _Stack) ->
    livery_resp:text(422,
        iolist_to_binary([<<"missing field: ">>, K]));
errors_to_resp(_Class, _Reason, _Stack) ->
    livery_resp:text(500, <<"internal error">>).
```

The wrapper catches `throw`, `error`, and `exit` from anything
downstream. `Class` is `throw | error | exit`.

## Rely on the default without a wrapper

When a handler runs inside `livery_req_proc` (the worker the H1/H2/H3
adapters spawn), a crash is automatically mapped to
`livery_resp:text(500, <<"internal server error">>)`. The wrapper is
for when you want a custom shape (validation errors as 400, business
errors as 422, etc.).

## Catch errors in tests

`livery_test_adapter:run/3` runs synchronously. Without a wrapper a
crash propagates up through the test process. Either:

- Add a wrapper in the stack you are testing, or
- Drive through `livery_req_proc:start_link/1` to exercise the
  default 500 mapping.

## Use domain exceptions as control flow

Throw to short-circuit from deep inside the call tree:

```erlang
authenticate(Req) ->
    case verify(Req) of
        {ok, U} -> U;
        error   -> throw({validation, <<"bad credentials">>})
    end.

show(Req) ->
    _User = authenticate(Req),
    livery_resp:json(200, payload()).
```

The `wrap` middleware turns the `throw({validation, ...})` into a
400 without explicit handler-level error handling.

## See also

- Reference: `livery_middleware`
- Tutorial: [Compose a middleware stack](../tutorials/middleware-stack.md)
