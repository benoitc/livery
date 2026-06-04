# How to migrate from Cowboy

## Problem

You have a service happily running on Cowboy, and you want to bring
it over to Livery. Ideally without throwing away your handlers and
starting from a blank file. Good news: most of the move is mechanical,
and a lot of Cowboy ceremony simply disappears.

## Mapping table

| Cowboy | Livery |
|---|---|
| `cowboy:start_clear/3`, `cowboy:start_tls/3` | `livery:start_service/1` |
| `cowboy_router:compile/1` | `livery_router:compile/1` |
| Handler `init(Req, Opts) -> {ok, Req, Opts}` | `fun(Req) -> Resp` |
| `cowboy_req:method/1` | `livery_req:method/1` |
| `cowboy_req:header/2,3` | `livery_req:header/2,3` |
| `cowboy_req:bindings/1` | `livery_req:bindings/1` |
| `cowboy_req:read_body/1,2` | `livery_body:read_all/2` (after stream body) |
| `cowboy_req:reply/2,3,4` | `livery_resp:text/2`, `:json/2`, `:empty/1`, builders |
| `cowboy_req:set_resp_header/3` | `livery_resp:with_header/3` |
| `cowboy_req:stream_reply/2,3` + `stream_body/3` | `livery_resp:stream/3` with `Emit` |
| `cowboy_loop` + `init/2` + `info/3` + `terminate/3` | `livery_resp:stream/3` with `receive` inside the producer |
| `cowboy_stream` access log handler | `livery_access_log` middleware |
| `cowboy_middleware` modules | `livery_middleware` modules |
| `cowboy_req:read_body/2` with `length` | `livery_body_limit` middleware + `livery_body:read_all/2` |

## Step-by-step

### 1. Convert one plain handler

Cowboy:

```erlang
init(Req0, Opts) ->
    Body = json:encode(#{ok => true}),
    Req1 = cowboy_req:reply(200, json_headers(), Body, Req0),
    {ok, Req1, Opts}.
```

Livery:

```erlang
handle(_Req) ->
    livery_resp:json(200, json:encode(#{ok => true})).
```

No `init`, no `Opts`, no `Req0`/`Req1` to thread through. The handler
takes a request and returns a response, and that is the whole story.

### 2. Convert a streaming `cowboy_loop` handler

Cowboy:

```erlang
init(Req0, Opts) ->
    Req1 = cowboy_req:stream_reply(200, ndjson_headers(), Req0),
    pipeline:subscribe(self(), Opts),
    {cowboy_loop, Req1, Opts, hibernate}.

info({progress, P}, Req, State) ->
    Line = [json:encode(#{pct => P}), <<"\n">>],
    cowboy_req:stream_body(Line, nofin, Req),
    {ok, Req, State, hibernate};
info(done, Req, State) ->
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State}.
```

Livery:

```erlang
handle(_Req) ->
    livery_resp:stream(200, ndjson_headers(), fun(Emit) ->
        pipeline:subscribe(self()),
        loop(Emit)
    end).

loop(Emit) ->
    receive
        {progress, P} ->
            Emit([json:encode(#{pct => P}), <<"\n">>]),
            loop(Emit);
        done ->
            ok
    end.
```

The producer fun runs in the per-request process, so it can `receive`
between emits and hibernate during the quiet stretches, exactly like
`cowboy_loop` did. The difference is that it is one plain function
instead of a three-callback state machine.

### 3. Convert the access log stream handler

For access logging, Cowboy has you register a custom `cowboy_stream`
handler module. In Livery the same job is just a middleware:

```erlang
Stack = [
    {livery_request_id, undefined},
    {livery_access_log, #{}}
    %% ...
].
```

`livery_access_log` emits one structured `logger` entry per
request with method, path, status, duration, and request id.

### 4. Convert the listener

Cowboy:

```erlang
{ok, _} = cowboy:start_clear(my_listener,
    [{port, 8080}],
    #{env => #{dispatch => Dispatch},
      middlewares => [cowboy_router, cowboy_handler],
      stream_handlers => [my_access_log, cowboy_stream_h]}).
```

Livery:

```erlang
{ok, _} = livery:start_service(#{
    http  => #{port => 8080},
    router => Router,
    middleware => Stack
}).
```

The H1/H2/H3 adapters are already wired in, so that same handler set
now serves all three protocols from a single `start_service/1` call.
And when you want to test a handler in EUnit, you can drive it
directly through `livery_test_adapter:run/3`.

## Validated against Cowboy

This guide is not hand-waving. `examples/livery_example_migration.erl`
is the "after" side of it: a plain handler, a small REST resource,
SSE, a streaming (`cowboy_loop`) replacement, and a WebSocket echo,
all in Livery. Then `test/livery_cowboy_parity_SUITE.erl` runs that
exact handler set behind both a live Cowboy listener and Livery, and
diffs the observable behaviour (status, content-type, body, framing)
over H1. After that it drives the same Livery handlers over H2 and H3,
the protocol upgrade Cowboy simply cannot give you. So the mappings in
this guide are not promises, they are checked by that suite.

## Cowboy concepts that do not move

A few things will not come across, and it is better to know up front:

- `cowboy_rest`: no equivalent, and none is on the roadmap. Write
  plain handlers and lean on the `livery_ext` extractors instead.
- `cowboy_req:cast/2`: you will not miss it. The request process owns
  its state, so send a message to `livery_req:engine_pid/1`, or use
  application-level pub/sub.
- `cowboy_stream` custom handlers: folded into middleware. There is no
  second extension point, and you will not need one.

## See also

- Concept: [Architecture](../concepts/architecture.md)
- Tutorial: [Your first service](../tutorials/your-first-service.md)
- Example: `examples/livery_example_migration.erl` and
  `test/livery_cowboy_parity_SUITE.erl`
