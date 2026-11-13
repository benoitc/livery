# How to parse a JSON body

`livery_ext:json/1` reads a JSON request body and decodes it into an
Erlang term. You need it when a handler accepts a JSON body and wants
the decoded value.

## Decode the body

```erlang
create_user(Req) ->
    case livery_ext:json(Req) of
        {ok, #{<<"email">> := Email}} ->
            ok = users:create(Email),
            livery_resp:empty(201);
        {ok, _Other} ->
            livery_resp:text(422, <<"email required">>);
        {error, invalid_json} ->
            livery_resp:text(400, <<"bad json">>);
        {error, no_body} ->
            livery_resp:text(400, <<"empty body">>);
        {error, {limit, max_size}} ->
            livery_resp:text(413, <<"body too large">>);
        {error, _} ->
            livery_resp:text(400, <<"body incomplete">>)
    end.
```

`livery_ext:json/1` returns `{ok, Term}` or `{error, Reason}`. It uses
the OTP `json` module (OTP 27+).

The H1, H2 and H3 adapters hand the body over as a stream, so
`livery_ext:json/1` reads it to the end before decoding it. It reads at
most 1 MiB and waits at most 5 seconds for each chunk. The other errors
are `timeout` and `{client_reset, Reason}`.

## Change the limits

Pass `max_size` (bytes) and `timeout` (milliseconds) to
`livery_ext:json/2`:

```erlang
livery_ext:json(Req, #{max_size => 65_536, timeout => 10_000}).
```

## Refuse large bodies early

Decoding a large body costs CPU and memory. Put `livery_body_limit`
before the handler in the stack:

```erlang
Stack = [
    {livery_body_limit, #{max => 65_536}},
    %% ... a Content-Length over 64 KiB gets a 413 before the handler;
    %% a longer body without one makes livery_ext:json/1 return
    %% {error, {limit, max_size}}
].
```

## See also

- Reference: `livery_ext`
- Guide: [Cap request body size](cap-body-size.md)
- Guide: [Read a streaming request body](read-streaming-body.md)
