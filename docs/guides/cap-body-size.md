# How to cap request body size

## Problem

Someone, by accident or on purpose, sends you a giant request body.
You would like to turn it away with a `413` early, before it ever
reaches your handler and ties up memory.

## Solution

Add `livery_body_limit` to the stack:

```erlang
Stack = [
    {livery_body_limit, #{max => 1_048_576}},  %% 1 MiB
    %% ... handler runs only for bodies <= 1 MiB
].
```

Any buffered body larger than `max` short-circuits with
`livery_resp:text(413, <<"payload too large">>)`, and your handler
never runs.

## Buffered only

One thing to keep in mind: `livery_body_limit` only inspects
`{buffered, IoData}` bodies, measured with `iolist_size/1`.
Streaming bodies (`{stream, _}`) pass straight through unchecked, so
for those you count bytes yourself as you drain the reader:

```erlang
consume(R, Acc) when Acc > Max -> too_large();
consume(R, Acc) ->
    case livery_body:read(R, 5_000) of
        {ok, Chunk, R1} -> consume(R1, Acc + iolist_size(Chunk));
        {done, _}       -> ok
    end.
```

## Different limits per route

An upload endpoint and a JSON API rarely want the same ceiling.
Mount the middleware separately per route group when the limits
differ:

```erlang
UploadStack  = [{livery_body_limit, #{max => 50_000_000}} | Common],
JsonApiStack = [{livery_body_limit, #{max => 65_536}}      | Common].
```

Each router group runs its own stack. Route-level mounting lives
in `livery_service` and `livery_router`.

## See also

- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
- Recipe: [Read a streaming request body](read-streaming-body.md)
