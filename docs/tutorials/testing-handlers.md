# Tutorial: Test your handlers

Livery handlers are pure functions over a request value, so most
tests do not need a socket. This tutorial covers the three test
levels and when to use each.

## Level 1: handler in isolation

A handler is `fun(Req) -> Resp`. Build a request, call it, assert
on the response.

```erlang
greet_uses_binding_test() ->
    Req = livery_req:new(#{
        method => <<"GET">>, path => <<"/hi/alice">>,
        bindings => #{<<"name">> => <<"alice">>}
    }),
    Resp = hello:greet(Req),
    ?assertEqual(200, livery_resp:status(Resp)),
    {full, Body} = livery_resp:body(Resp),
    ?assertEqual(<<"hello, alice">>, iolist_to_binary(Body)).
```

No adapter, no middleware. The cheapest level. Use it for branching
logic inside a single handler.

## Level 2: handler plus middleware via run/3

`livery_test_adapter:run/3` drives a request through a middleware
stack and a handler, captures the emitted response, and returns
typed accessors.

```erlang
auth_required_test() ->
    Stack = [{my_auth, #{required => true}}],
    Cap = livery_test_adapter:run(
        Stack,
        fun (_R) -> error(must_not_be_called) end,
        #{}),
    ?assertEqual(401, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"missing token">>, livery_test_adapter:body(Cap)).
```

`run/3` runs synchronously in the test process. Use it for
middleware ordering, short-circuit behavior, and assertions on
emitted headers/body/trailers.

The request spec map accepts any field of `#livery_req{}`:
`method`, `path`, `raw_query`, `headers`, `bindings`, `body`,
`peer`, `tls`, and `meta`.

## Level 3: through the per-request process

Sometimes you want the request to run in its own process — to
verify crash-to-500 mapping, or to read body messages from the
adapter's mailbox. Use `livery_req_proc:start_link/1`.

```erlang
handler_crash_returns_500_test() ->
    Tab = livery_test_adapter:start(),
    try
        Stream = livery_test_adapter:new_stream(Tab),
        Req = livery_req:new(#{method => <<"GET">>}),
        {ok, Pid} = livery_req_proc:start_link(#{
            adapter => livery_test_adapter,
            stream => Stream,
            req => Req,
            stack => [],
            handler => fun(_R) -> error(boom) end
        }),
        wait_for_exit(Pid),
        Cap = livery_test_adapter:capture(Stream),
        ?assertEqual(500, livery_test_adapter:status(Cap))
    after
        livery_test_adapter:stop(Tab)
    end.

wait_for_exit(Pid) ->
    Ref = erlang:monitor(process, Pid),
    receive {'DOWN', Ref, _, _, _} -> ok after 500 -> error(timeout) end.
```

`livery_req_proc:start_link/1` spawns the same worker process the
H1/H2/H3 adapters use. Crashes inside the handler are mapped to a
500 response and the process exits normally.

## Level 4: the parity SUITE

`test/livery_parity_SUITE.erl` runs a shared handler matrix
through `livery_test_adapter` today, and will run the same matrix
through `livery_h1`, `livery_h2`, and `livery_h3` once those land.
Add your service's cross-protocol invariants there if they belong
in the framework's regression suite.

## Picking a level

| Goal | Level |
|---|---|
| Inside a single handler | 1: call the function |
| Middleware composition or short-circuit | 2: `run/3` |
| Crash semantics, body-message routing, multi-request | 3: `req_proc` |
| Cross-adapter behaviour | 4: parity SUITE |

In practice 90 % of tests are level 1 or level 2.
