# How to catch handler errors

When a handler crashes (`error(badmatch)`, `throw(_)`, division by
zero, etc.) you want to send a response you chose instead of letting
the exit spread. Wrap the rest of the stack with `livery_middleware:wrap/1` and
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
adapters spawn), a crash becomes
`livery_resp:text(500, <<"internal server error">>)` on its own. Use
the wrapper when you want a different response (validation errors as
400, business errors as 422, etc.).

## Catch errors in tests

`livery_test_adapter:run/3` runs in the calling process. Without a
wrapper, it turns a crash into the same
`500 internal server error` response, so your test sees the status
instead of the exception. To test your own error responses, add a
wrapper in the stack you are testing.

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
400, with no error handling in the handler itself.

## See also

- Reference: `livery_middleware`
- Tutorial: [Compose a middleware stack](../tutorials/middleware-stack.md)
