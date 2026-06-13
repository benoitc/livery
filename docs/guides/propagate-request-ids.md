# How to propagate request IDs

`livery_request_id` gives every request a stable id that appears in
logs and on the response, and that clients can pin to track work
across services. You need it as soon as a request crosses more than
one log line or one service.

## Add it to the stack

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
`livery_request_id`, it honors the value and keeps the chain
consistent.

## Place it first

`livery_request_id` should be the outermost entry in the stack so
every response carries the id, including ones produced by
short-circuiting middleware below it.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Guide: [Log every request](log-requests.md)
