# How to parse a JSON body

`livery_ext:json/1` decodes a JSON request body into an Erlang term.
You need it when a handler accepts a JSON-encoded body and wants the
decoded value.

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
        {error, not_buffered} ->
            livery_resp:text(500, <<"body must be buffered">>)
    end.
```

`livery_ext:json/1` returns `{ok, Term}` or `{error, Reason}`. It uses
the OTP `json` module (OTP 27+).

## Buffer a streaming body first

JSON extraction requires the body to be in
`#livery_req{body = {buffered, _}}` form. Streaming bodies must be
drained first via `livery_body:read_all/2`:

```erlang
{stream, Reader} = livery_req:body(Req),
{ok, Bytes, _} = livery_body:read_all(Reader, 5_000),
Req1 = livery_req:set_body({buffered, Bytes}, Req),
{ok, Term} = livery_ext:json(Req1).
```

The H1/H2/H3 adapters can be configured to buffer up to a per-route
threshold automatically.

## Cap the size first

JSON parsing on a large body wastes CPU and memory. Put
`livery_body_limit` upstream:

```erlang
Stack = [
    {livery_body_limit, #{max => 65_536}},
    %% ... handler runs only for bodies <= 64 KiB
].
```

## See also

- Reference: `livery_ext`
- Guide: [Cap request body size](cap-body-size.md)
- Guide: [Read a streaming request body](read-streaming-body.md)
