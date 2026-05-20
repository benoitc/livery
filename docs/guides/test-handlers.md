# How to test handlers without a socket

## Problem

You want fast unit tests for a handler or a stack, without binding
ports, without HTTP clients, without docker.

## Solution

`livery_test_adapter:run/3` runs a synthetic request through a
stack and handler and captures the emitted response.

```erlang
ok_test() ->
    Cap = livery_test_adapter:run(
        [], fun my_handler:show/1,
        #{method => <<"GET">>, path => <<"/items/1">>,
          bindings => #{<<"id">> => <<"1">>}}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"application/json">>,
                 livery_test_adapter:header(<<"content-type">>, Cap)).
```

## Build a request spec

The spec map accepts any `#livery_req{}` field. Defaults: GET on `/`
over `h1`.

```erlang
#{
    method   => <<"POST">>,
    path     => <<"/items">>,
    raw_query => <<"draft=true">>,
    headers  => [{<<"content-type">>, <<"application/json">>}],
    bindings => #{<<"id">> => <<"42">>},
    body     => {buffered, <<"{\"name\":\"saw\"}">>},
    peer     => {{127,0,0,1}, 4242}
}
```

## Inspect the response

| Accessor | Returns |
|---|---|
| `livery_test_adapter:status/1` | `100..599 \| undefined` |
| `livery_test_adapter:headers/1` | `[{binary(), binary()}]` |
| `livery_test_adapter:header/2` | one header value or `undefined` |
| `livery_test_adapter:body/1` | concatenated body as `binary()` |
| `livery_test_adapter:body_chunks/1` | individual chunks as `[iodata()]` |
| `livery_test_adapter:trailers/1` | trailers or `undefined` |
| `livery_test_adapter:reset_reason/1` | reset reason if the stream was aborted |
| `livery_test_adapter:end_stream/1` | boolean, true after the final frame |

## When run/3 is not enough

Spawn through `livery_req_proc` if you need the per-request worker
semantics: 500-on-crash, body-message routing via mailbox,
multi-request concurrency.

```erlang
{ok, Pid} = livery_req_proc:start_link(#{
    adapter => livery_test_adapter,
    stream => Stream,
    req => Req,
    stack => Stack,
    handler => Handler
}),
wait_for_exit(Pid),
Cap = livery_test_adapter:capture(Stream).
```

See [Testing handlers](../tutorials/testing-handlers.md) for the
four test levels and when to use each.

## Drive body messages

Streaming handlers `receive` body chunks. Feed them through the
test adapter helper:

```erlang
Stream = livery_test_adapter:new_stream(Tab),
Ref = make_ref(),
livery_test_adapter:feed_body(Ref, Pid, {data, <<"chunk">>}),
livery_test_adapter:feed_body(Ref, Pid, eof).
```

## See also

- Reference: `livery_test_adapter`
- Tutorial: [Test your handlers](../tutorials/testing-handlers.md)
