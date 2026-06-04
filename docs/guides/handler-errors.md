# How to catch handler errors

## Problem

Sooner or later a handler crashes - a `badmatch`, a stray `throw`, a
division by zero. When that happens you would much rather send the
client a clean, controlled response than let the exit propagate and
turn into noise.

## Solution

Wrap the rest of the stack with `livery_middleware:wrap/1` and decide,
in one place, how each kind of failure should look to the client:

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
downstream, and tells you which one it was: `Class` is
`throw | error | exit`.

## Without a wrapper

You are not left exposed without one. When a handler runs inside
`livery_req_proc` (the worker the H1/H2/H3 adapters spawn), a crash
is automatically turned into
`livery_resp:text(500, <<"internal server error">>)`. The wrapper is
for when that generic 500 is not enough and you want a shape of your
own: validation errors as 400, business errors as 422, and so on.

## In tests

One gotcha worth knowing: `livery_test_adapter:run/3` runs
synchronously, so without a wrapper a crash propagates straight up
through your test process. You have two ways around it:

- Add a wrapper in the stack you are testing, or
- Drive through `livery_req_proc:start_link/1` to exercise the
  default 500 mapping.

## Domain exceptions as control flow

There is a nice trick hiding here: you can `throw` to short-circuit
from deep inside the call tree, no error plumbing required.

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

The `wrap` middleware quietly turns that `throw({validation, ...})`
into a 400, and your handler never has to mention error handling at
all.

## See also

- Reference: `livery_middleware`
- Tutorial: [Compose a middleware stack](../tutorials/middleware-stack.md)
