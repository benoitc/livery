# How to share config across handlers

## Problem

Your handlers all need the same things: a database pool, a cache, some
settings you read at boot. You do not want to capture them in a closure
for every handler, reach for a global, or smuggle them through the
per-request `meta` map (which is really for per-request scratch). You
want one value, set once at startup, that any handler can read.

## Solution

Pass `config` when you start the service. It is whatever you like, most
often a map of handles, and the same value reaches every request:

```erlang
{ok, Pid} = livery:start_service(#{
    http   => #{port => 8080},
    config => #{db => DbPool, cache => CachePid},
    router => Router
}).
```

A handler reads it with `livery_req:config/1` for the whole value:

```erlang
list_users(Req) ->
    #{db := Db} = livery_req:config(Req),
    livery_resp:json(200, json:encode(users:all(Db))).
```

or `livery_req:config/2,3` to pull one key out of a map config:

```erlang
list_users(Req) ->
    Db = livery_req:config(db, Req),
    livery_resp:json(200, json:encode(users:all(Db))).
```

Middleware sees the same request, so it can read config too:

```erlang
call(Req, Next, _Opts) ->
    Limiter = livery_req:config(limiter, Req),
    enforce(Limiter, Req, Next).
```

## A record, if you prefer

Config is any term, so a record gives you a little more discipline than
a map:

```erlang
%% -record(app, {db, cache}).
show(Req) ->
    App = livery_req:config(Req),
    livery_resp:json(200, fetch(App#app.db)).
```

## A single listener, or one config per listener

`livery:start_listener/2` takes `config` the same way:

```erlang
{ok, _} = livery:start_listener(livery_h1, #{
    port => 8080, config => App, stack => Stack, handler => Handler
}).
```

And a `config` inside one protocol's map on `start_service/1` overrides
the service-wide one for that listener, handy when, say, your TLS
endpoint should point at a different pool.

## config vs meta

Two different jobs, easy to mix up:

- **`config`** is service-wide and set at startup: the same value for
  every request, read-only. Use it for shared handles and settings.
- **`meta`** is per-request scratch a middleware writes for this one
  request, like the authenticated user or a trace id. See
  [Write a custom middleware](custom-middleware.md).

## Testing

Handlers stay testable with no socket: put `config` in the request spec.

```erlang
Cap = livery_test_adapter:run([], fun my_app:list_users/1,
    #{method => <<"GET">>, config => #{db => FakeDb}}).
```

## See also

- Concept: [Request and response model](../concepts/request-and-response.md)
- Guide: [Write a custom middleware](custom-middleware.md)
- Reference: `livery_req`, `livery_service`
