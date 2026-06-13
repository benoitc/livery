# How to cap request body size

`livery_body_limit` is a middleware that rejects oversized request
bodies with a `413` before they reach the handler. You need it when a
client could send a body larger than your handler is prepared to
buffer.

## Add it to the stack

```erlang
Stack = [
    {livery_body_limit, #{max => 1_048_576}},  %% 1 MiB
    %% ... handler runs only for bodies <= 1 MiB
].
```

A buffered body whose size exceeds `max` short-circuits with
`livery_resp:text(413, <<"payload too large">>)`. The handler is not
invoked.

## Count streaming bodies yourself

`livery_body_limit` inspects `{buffered, IoData}` bodies and uses
`iolist_size/1`. Streaming bodies (`{stream, _}`) pass through
unchecked, so count bytes in the handler as you drain the reader:

```erlang
consume(R, Acc) when Acc > Max -> too_large();
consume(R, Acc) ->
    case livery_body:read(R, 5_000) of
        {ok, Chunk, R1} -> consume(R1, Acc + iolist_size(Chunk));
        {done, _}       -> ok
    end.
```

## Set different limits per route

Mount the middleware separately per route group when limits differ:

```erlang
UploadStack  = [{livery_body_limit, #{max => 50_000_000}} | Common],
JsonApiStack = [{livery_body_limit, #{max => 65_536}}      | Common].
```

Each router group runs its own stack. Route-level mounting lives in
`livery_service` and `livery_router`.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Guide: [Read a streaming request body](read-streaming-body.md)
