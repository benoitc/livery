# How to cap request body size

`livery_body_limit` is a middleware that rejects oversized request
bodies with a `413` before they reach the handler. You need it when a
client could send a body larger than your handler is ready to
hold in memory.

## Add it to the stack

```erlang
Stack = [
    {livery_body_limit, #{max => 1_048_576}},  %% 1 MiB
    %% ... handler runs only for bodies <= 1 MiB
].
```

A request whose `Content-Length` is above `max` gets
`413 Payload Too Large` before the handler runs. A body that arrives
without a length (chunked, or HTTP/2 and HTTP/3 data frames) reaches the
handler through a reader limited to `max` bytes: reading past it returns
`{error, body_too_large, _}`, and the body helpers report it too:

```erlang
case livery_body:read_all(Reader) of
    {ok, Body, _} -> handle(Body);
    {error, body_too_large, _} -> livery_resp:text(413, <<"payload too large">>)
end.
```

A handler that never reads the body is not affected.

## Set different limits per route

When limits differ, mount the middleware separately for each group of
routes:

```erlang
UploadStack  = [{livery_body_limit, #{max => 50_000_000}} | Common],
JsonApiStack = [{livery_body_limit, #{max => 65_536}}      | Common].
```

Each group of routes runs its own stack. You attach a stack to routes
with `livery_service` and `livery_router`.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Guide: [Read a streaming request body](read-streaming-body.md)
