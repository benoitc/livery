# How to propagate request IDs

## Problem

A request comes in, fans out to three services, and something goes
wrong somewhere. Without a shared id, good luck stitching the logs
back together. What you want is one stable id per request that shows
up in your logs, rides back out on the response, and follows the work
across every service it touches.

## Solution

```erlang
Stack = [
    {livery_request_id, undefined}
    %% ... other middleware and handler
].
```

`livery_request_id`:

- Looks at `X-Request-ID` on the inbound request.
- If present, reuses it.
- If absent, generates a 32-character lowercase hex id from
  `crypto:strong_rand_bytes/1`.
- Stores it on `#livery_req{}` via `livery_req:set_req_id/2`.
- Echoes the same value on the response as `X-Request-ID`.

## Read it from your code

```erlang
my_handler(Req) ->
    Id = livery_req:req_id(Req),
    logger:info(#{event => start, request_id => Id}),
    livery_resp:text(200, <<>>).
```

## Pass it to downstream calls

```erlang
my_handler(Req) ->
    Id = livery_req:req_id(Req),
    {ok, _} = http_client:get("https://other/api",
                              [{<<"x-request-id">>, Id}]),
    livery_resp:empty(204).
```

When the downstream service also runs Livery with
`livery_request_id`, it sees the header, reuses your value, and the
chain stays consistent end to end.

## Place it first

Make `livery_request_id` the outermost entry in the stack. That way
every response carries the id, even the ones produced by
short-circuiting middleware sitting below it.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Recipe: [Log every request](log-requests.md)
