# How to parse a JSON body

## Problem

A client is sending you JSON, and your handler wants it as a proper
Erlang term rather than a blob of bytes. This is the everyday case for
any JSON API, and Livery makes the decode a one-liner.

## Solution

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

`livery_ext:json/1` hands you back `{ok, Term}` or `{error, Reason}`.
Under the hood it leans on the OTP `json` module (OTP 27+), so there
is nothing extra to pull in.

## Body must be buffered

To decode JSON, the body has to be sitting in memory as
`#livery_req{body = {buffered, _}}`. If you have a streaming body
instead, drain it first with `livery_body:read_all/2`:

```erlang
{stream, Reader} = livery_req:body(Req),
{ok, Bytes, _} = livery_body:read_all(Reader, 5_000),
Req1 = livery_req:set_body({buffered, Bytes}, Req),
{ok, Term} = livery_ext:json(Req1).
```

If you would rather not do this by hand, the H1/H2/H3 adapters can
buffer up to a per-route threshold for you automatically.

## Cap the size first

Parsing a huge JSON body burns CPU and memory for nothing, and it is
an easy way for someone to hurt you. Put `livery_body_limit` upstream
and let it reject oversized bodies before you ever parse them:

```erlang
Stack = [
    {livery_body_limit, #{max => 65_536}},
    %% ... handler runs only for bodies <= 64 KiB
].
```

## See also

- Reference: `livery_ext`
- Recipe: [Cap request body size](cap-body-size.md)
- Recipe: [Read a streaming request body](read-streaming-body.md)
