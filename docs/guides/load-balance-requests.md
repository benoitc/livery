# How to load-balance outbound requests

## Problem

The service you call runs as several replicas, and you want to spread
your requests across them, lean away from a slow one, and stop sending to
a dead one until it recovers. You do not want a separate proxy in front;
you want the client to do it.

## Solution

Add a `balance` layer to the client. Instead of a `base_url`, you give it
a pool of endpoints and pass paths; the layer picks an endpoint per
request and supplies the host.

```erlang
Client = livery_client:new(#{
    stack => [
        livery_client:retry(#{max => 3}),
        livery_client:balance(#{
            name      => users,
            endpoints => [
                <<"http://10.0.0.1:8080">>,
                <<"http://10.0.0.2:8080">>,
                <<"http://10.0.0.3:8080">>
            ]
        })
    ]
}),
{ok, Resp} = livery_client:get(Client, <<"/users/42">>),
200 = livery_client:status(Resp).
```

By default the layer uses power-of-two-choices: it samples two endpoints
and sends to the one with fewer in-flight requests, which resists piling
onto a slow node. Pass `policy => round_robin` for plain rotation.

## Health: ejection and recovery

The balancer watches outcomes. An endpoint that fails `eject_after`
times in a row (default 5) is ejected from the pool for `eject_for` ms
(default 10000). A failure is any `{error, _}` or, by default, any
response with status `>= 500`, so a replica answering `503` is treated as
unhealthy even though the call technically returned. Override what counts
with `fail_status`:

```erlang
livery_client:balance(#{
    name        => users,
    endpoints   => Endpoints,
    eject_after => 3,
    eject_for   => 5000,
    fail_status => [500, 502, 503, 504]
}).
```

Recovery is lazy and safe: once the cooldown passes, the next request is
leased as a single probe (an atomic compare-and-swap means only one
caller probes, even under load). If it succeeds the endpoint rejoins; if
it fails the endpoint stays out for another cooldown. Stack `retry` above
`balance`, as shown, and that one probe failure is retried onto a healthy
endpoint, invisibly to the caller.

If every endpoint is ejected, a call returns `{error, no_endpoint}`.

## Changing the pool at runtime

A deploy adds a replica, or a node drains. Adjust the live pool without
rebuilding the client:

```erlang
ok = livery_client:add_endpoint(users, <<"http://10.0.0.4:8080">>),
ok = livery_client:remove_endpoint(users, <<"http://10.0.0.1:8080">>).
```

The pool is identified by its `name`, so every client built with the same
name shares it. The `endpoints` list seeds the pool once, on first use;
after that your `add`/`remove` calls are authoritative and a later
request will not bring a removed endpoint back.

## Discovery

`endpoints` can be a `{Module, Arg}` pair naming a `livery_client_discover`
provider instead of a fixed list. The shipped provider is static; a
custom one can resolve endpoints from DNS or a registry:

```erlang
livery_client:balance(#{name => users, endpoints => {my_discovery, prod}}).
```

## See also

- Guide: [Make outbound HTTP requests](make-http-requests.md)
- Concept: [The middleware pipeline](../concepts/middleware-pipeline.md)
- Reference: `livery_client`, `livery_client_balance`, `livery_client_discover`
