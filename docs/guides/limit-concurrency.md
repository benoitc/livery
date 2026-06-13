# How to limit concurrency (load-shedding)

`livery_concurrency` is a middleware that caps the number of in-flight
requests and sheds the overflow with `503`. You need it when a traffic
spike can pile up more requests than your workers (or a downstream model)
can handle, and you would rather drop the excess than let the service
collapse.

## Add it to the stack

Build the limiter with the `limiter/1` factory, which creates the shared
counter once, and put it in your stack:

```erlang
Stack = [
    {livery_concurrency, livery_concurrency:limiter(1000)}
    %% ... handler runs only while fewer than 1000 requests are in flight
].
```

While at or under the limit the request proceeds. Over the limit it is
shed immediately with `503 Service Unavailable` and the handler is never
called. The counter is a lock-free `atomics` cell shared across request
processes, so there is no extra process and no lock.

## Change the response

```erlang
livery_concurrency:limiter(500, #{
    status => 429,                 %% default 503
    body => <<"slow down">>,       %% default <<"service unavailable">>
    retry_after => 5               %% adds Retry-After: 5 (seconds, or a binary)
})
```

## Use global and per-route limits

`limiter/1,2` returns a State carrying its own counter, so each call is
an independent limiter:

```erlang
%% one global limit in the service stack
ServiceStack = [{livery_concurrency, livery_concurrency:limiter(2000)}],

%% a tighter limit on an expensive route group
InferStack = [{livery_concurrency, livery_concurrency:limiter(8)} | Common].
```

## Notes

- A slot is held from admission until the handler RETURNS its response.
  Body streaming runs after that (outside the middleware stack), so the
  slot does not cover a long streamed/SSE body. For inference that
  streams tokens, gate the streaming work yourself if you need to bound
  active streams.
- The slot is always released, including when the handler crashes.
- The limit is approximate under a burst (a request that increments past
  the limit decrements again), which is the expected behavior for
  load-shedding.

## See also

- Reference: `livery_concurrency`
- Guide: [Add per-request deadlines](add-deadlines.md)
- Guide: [Cap request body size](cap-body-size.md)
