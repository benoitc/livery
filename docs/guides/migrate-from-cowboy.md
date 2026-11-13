# How to migrate from Cowboy

This guide gives the Livery equivalent of Cowboy's request, routing, and
streaming APIs. You need it when you have a service running on Cowboy
and you want to move it to Livery without rewriting handlers from scratch.

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

No `init`, no `Opts`, no `Req0/Req1` to pass from one call to the
next.

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

The producer fun runs in the request's own process. It can `receive`
between two calls to `Emit` and, on OTP 28 or later, hibernate while it
waits with `erlang:hibernate/0`, as `cowboy_loop` does, with one
function instead of three callbacks. Do not use `erlang:hibernate/3`
there: it throws away the call stack, so the stream is never finished.

### 3. Convert the access log stream handler

Cowboy registers a custom `cowboy_stream` handler module for access
logging. In Livery the equivalent is a middleware:

```erlang
Stack = [
    {livery_request_id, undefined},
    {livery_access_log, #{}}
    %% ...
].
```

`livery_access_log` writes one structured `logger` entry per request with
method, path, status, duration, and request id.

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

The H1, H2 and H3 adapters are already in place, so the same handlers
serve all three protocols from one `start_service/1` call. You can also
call your handlers from EUnit through `livery_test_adapter:run/3`.

## Validated against Cowboy

`examples/livery_example_migration.erl` is the "after" side of this
guide: a plain handler, a small REST resource, SSE, a streaming
(`cowboy_loop`) replacement, and a WebSocket echo, all in Livery.
`test/livery_cowboy_parity_SUITE.erl` runs those same handlers behind
both a live Cowboy listener and Livery and compares what a client sees
(status, content-type, body, framing) over H1, then runs the same
Livery handlers over H2 and H3 to show the protocol upgrade Cowboy cannot
give you. That suite checks the mappings in this guide.

## Cowboy concepts that do not move

- `cowboy_rest`: there is no equivalent. Use plain handlers with
  `livery_ext` extractors. No REST helper module is planned for now.
- `cowboy_req:cast/2`: not needed. The request process owns its state;
  send a message to `livery_req:engine_pid/1` or use application-level
  pub/sub.
- `cowboy_stream` custom handlers: replaced by middleware. Livery has no
  second place to hook into a request.

## See also

- Concept: [Architecture](../concepts/architecture.md)
- Tutorial: [Your first service](../tutorials/your-first-service.md)
- Example: `examples/livery_example_migration.erl` and
  `test/livery_cowboy_parity_SUITE.erl`
