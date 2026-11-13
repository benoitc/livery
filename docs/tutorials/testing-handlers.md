# Tutorial: Test your handlers

A Livery handler takes a request value and returns a response value,
so most of your tests do not need a socket. In this tutorial you learn
the four test levels and when to use each. It is for you once you have
a handler or two and want to test them properly.

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

No adapter, no middleware. The simplest and fastest level. Use it for
the different paths through a single handler.

## Level 2: handler plus middleware via run/3

`livery_test_adapter:run/3` drives a request through a middleware
stack and a handler, records the response it sends, and gives you
functions to read it.

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

`run/3` runs in the test process and returns when the response is
complete. Use it to check the order of your middleware, a middleware
that answers without calling the handler, and the headers, body and
trailers that were sent.

The request spec map accepts any field of `#livery_req{}`:
`method`, `path`, `raw_query`, `headers`, `bindings`, `body`,
`peer`, `tls`, and `meta`.

## Level 3: through the per-request process

Sometimes you want the request to run in its own process, to check
that a crash becomes a 500, or to read body messages from the adapter's
mailbox. Use `livery_req_proc:start_link/1`.

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
H1/H2/H3 adapters use. A crash inside the handler becomes a 500
response, and the process exits normally.

## Level 4: the parity SUITE

`test/livery_parity_SUITE.erl` runs one set of handlers through
`livery_test_adapter`, `livery_h1`, `livery_h2`, and `livery_h3`, and
compares what a client sees from each. If your service relies on a
behaviour that must be the same on every protocol, and it belongs in
the framework's own regression tests, add it there.

## Picking a level

| Goal | Level |
|---|---|
| Inside a single handler | 1: call the function |
| Middleware order, or a middleware that answers early | 2: `run/3` |
| What a crash does, body messages, several requests | 3: `req_proc` |
| Cross-adapter behaviour | 4: parity SUITE |

In practice 90 % of tests are level 1 or level 2.
