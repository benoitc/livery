# How to load-balance outbound requests

The `balance` layer spreads your outbound calls across a pool of
endpoints, sends less to a slow replica, and stops sending to a dead
one until it recovers. You need it when the service you call runs as
several replicas and you want the client to do the balancing, with no
separate proxy in front.

## Add a balance layer

Instead of a `base_url`, give the client a pool of endpoints and pass
paths. The layer picks an endpoint per request and supplies the host.

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

By default the layer uses "power of two choices": it picks two endpoints
at random and sends to the one with fewer requests in progress, so
requests do not pile up on a slow node. Pass `policy => round_robin` to
take the endpoints in turn instead.

## Tune ejection and recovery

The balancer keeps track of how each call ends. An endpoint that fails
`eject_after` times in a row (default 5) is taken out of the pool for
`eject_for` ms (default 10000). A failure is any `{error, _}` or, by
default, any response with status `>= 500`, so a replica answering `503`
counts as unhealthy even though the call did return. Change what counts
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

Nothing checks the endpoint in the background: once the cooldown
passes, the next request is sent to it as a single trial (an atomic
compare-and-swap makes sure only one caller does this, even under load).
If it succeeds the endpoint rejoins the pool; if it fails the endpoint
stays out for another cooldown. Put `retry` above `balance`, as in the
first example, and a failed trial is retried on a healthy endpoint
without the caller noticing.

If every endpoint is ejected, a call returns `{error, no_endpoint}`.

## Change the pool at runtime

When a deploy adds a replica, or a node is being taken down, change the
pool while it runs, without rebuilding the client:

```erlang
ok = livery_client:add_endpoint(users, <<"http://10.0.0.4:8080">>),
ok = livery_client:remove_endpoint(users, <<"http://10.0.0.1:8080">>).
```

The pool is identified by its `name`, so every client built with the same
name shares it. The `endpoints` list fills the pool once, on first use;
after that only your `add`/`remove` calls change it, and a later request
will not bring a removed endpoint back.

## Resolve endpoints from discovery

`endpoints` can be a `{Module, Arg}` pair naming a `livery_client_discover`
provider instead of a fixed list. The provider that comes with Livery
returns a fixed list; one you write can look endpoints up in DNS or a
service registry:

```erlang
livery_client:balance(#{name => users, endpoints => {my_discovery, prod}}).
```

## See also

- Guide: [Make outbound HTTP requests](make-http-requests.md)
- Concept: [The middleware pipeline](../concepts/middleware-pipeline.md)
- Reference: `livery_client`, `livery_client_balance`, `livery_client_discover`
