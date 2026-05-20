# How to cap request body size

## Problem

You want to reject oversized request bodies with a `413` before
they reach the handler.

## Solution

Add `livery_body_limit` to the stack:

```erlang
Stack = [
    {livery_body_limit, #{max => 1_048_576}},  %% 1 MiB
    %% ... handler runs only for bodies <= 1 MiB
].
```

A buffered body whose size exceeds `max` short-circuits with
`livery_resp:text(413, <<"payload too large">>)`. The handler is
not invoked.

## Buffered only (Phase 1)

`livery_body_limit` inspects `{buffered, IoData}` bodies and uses
`iolist_size/1`. Streaming bodies (`{stream, _}`) pass through
unchecked: incremental enforcement on a streaming reader lands with
the H1 adapter in Phase 2.

For streaming intake, count bytes manually in the handler:

```erlang
consume(R, Acc) when Acc > Max -> too_large();
consume(R, Acc) ->
    case livery_body:read(R, 5_000) of
        {ok, Chunk, R1} -> consume(R1, Acc + iolist_size(Chunk));
        {done, _}       -> ok
    end.
```

## Different limits per route

Mount the middleware separately per route group when limits differ:

```erlang
UploadStack  = [{livery_body_limit, #{max => 50_000_000}} | Common],
JsonApiStack = [{livery_body_limit, #{max => 65_536}}      | Common].
```

Each router group runs its own stack. Route-level mounting lives
in `livery_service` and `livery_router` (Phase 4).

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Recipe: [Read a streaming request body](read-streaming-body.md)
