# How to propagate request IDs

`livery_request_id` gives every request an id that appears in logs and
on the response. A client can send its own id, to follow one piece of
work across services. You need it as soon as one request leaves more
than one log line, or goes through more than one service.

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
- Stores it on `#livery_req{}` with `livery_req:set_req_id/2`.
- Sends the same value back on the response as `X-Request-ID`.

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

If the service you call also runs Livery with `livery_request_id`, it
keeps that value, so the whole chain shares one id.

## Place it first

Put `livery_request_id` first in the stack (the outermost entry), so
every response carries the id, even one that a middleware further down
returns early without calling the handler.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Guide: [Log every request](log-requests.md)
