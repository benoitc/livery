# Quickstart

Write your first Livery handler and exercise it end-to-end through
the in-memory adapter. This takes about five minutes. No socket is
involved; the same handler runs unchanged behind the H1, H2, and H3
adapters when you serve it with `livery:start_service/1`.

## Prerequisites

- Erlang/OTP 27 or later (Livery uses the standard library `json`
  module).
- `rebar3`.

## Add the dependency

In `rebar.config`:

```erlang
{deps, [
    {livery, {git, "https://github.com/benoitc/livery.git", {branch, "main"}}}
]}.
```

## Write a handler

`src/hello.erl`:

```erlang
-module(hello).
-export([index/1, greet/1]).

index(_Req) ->
    livery_resp:text(200, <<"hello, world">>).

greet(Req) ->
    Name = livery_req:binding(<<"name">>, Req, <<"stranger">>),
    livery_resp:text(200, [<<"hello, ">>, Name]).
```

## Run it from EUnit

`test/hello_tests.erl`:

```erlang
-module(hello_tests).
-include_lib("eunit/include/eunit.hrl").

index_test() ->
    Cap = livery_test_adapter:run(
        [], fun hello:index/1,
        #{method => <<"GET">>, path => <<"/">>}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"hello, world">>, livery_test_adapter:body(Cap)).

greet_test() ->
    Cap = livery_test_adapter:run(
        [], fun hello:greet/1,
        #{method => <<"GET">>, path => <<"/hi/alice">>,
          bindings => #{<<"name">> => <<"alice">>}}),
    ?assertEqual(<<"hello, alice">>, livery_test_adapter:body(Cap)).
```

Then:

```
rebar3 eunit
```

Both tests should pass.

## Add a middleware stack

```erlang
Stack = [
    {livery_request_id, undefined},
    {livery_access_log, #{}},
    {livery_body_limit, #{max => 1_048_576}}
],
Cap = livery_test_adapter:run(Stack, fun hello:index/1, #{}).
```

The response will carry an `X-Request-ID` header, the access log
will emit one entry via `logger:log/2`, and any inbound body over
1 MiB will be rejected with a `413` before the handler runs.

## What's next

- Learn the model: [Tutorials](tutorials/your-first-service.md).
- Solve a specific task: [How-to guides](README.md#how-to-guides).
- Migrate an existing service: [Migrate from Cowboy](guides/migrate-from-cowboy.md).
