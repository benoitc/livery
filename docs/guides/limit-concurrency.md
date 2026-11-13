# How to limit concurrency (load-shedding)

`livery_concurrency` is a middleware that caps the number of in-flight
requests and turns the rest away with `503`. You need it when a traffic
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

Up to the limit, the request goes through. Past it, the request is
refused at once with `503 Service Unavailable` and the handler is never
called. The counter is an `atomics` cell shared by all request
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

`limiter/1,2` returns a State with its own counter, so each call makes
a separate limiter:

```erlang
%% one global limit in the service stack
ServiceStack = [{livery_concurrency, livery_concurrency:limiter(2000)}],

%% a tighter limit on an expensive route group
InferStack = [{livery_concurrency, livery_concurrency:limiter(8)} | Common].
```

## Notes

- A slot is held from admission until the response has been sent,
  streamed bodies (SSE, chunked, files) included, so a long token stream
  counts for as long as it runs.
- The slot is always released, including when the handler crashes.
- Under a burst the limit is approximate (a request that pushes the
  counter past the limit takes it back down), which is what you expect
  when shedding load.

## See also

- Reference: `livery_concurrency`
- Guide: [Add per-request deadlines](add-deadlines.md)
- Guide: [Cap request body size](cap-body-size.md)
