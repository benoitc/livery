# How to read headers

`livery_req` reads request header values. You need it whenever a
handler branches on `Content-Type`, `Accept`, a custom `X-` header,
or any other field the client sent.

## Read a single header

```erlang
ContentType = livery_req:header(<<"content-type">>, Req),
%% or, with a default:
Accept = livery_req:header(<<"accept">>, Req, <<"*/*">>).
```

Header names are matched case-insensitively. Both
`<<"Content-Type">>` and `<<"content-type">>` work; Livery lowercases
on ingest so lookups are constant-time after that.

## Read repeated headers

`livery_req:headers_all/2` returns every value for the header in wire
order. Useful for `Set-Cookie`, `Vary`, and comma-separated lists like
`Accept-Encoding`:

```erlang
Accepts = livery_req:headers_all(<<"accept">>, Req).
```

## Read all headers

```erlang
livery_req:headers(Req)        %% [{Name, Value}] (lowercased names)
livery_req:has_header(<<"x-trace">>, Req)
```

## Read from a middleware

Headers can also be inspected through extractors:

```erlang
case livery_ext:header(<<"x-feature-flag">>, Req) of
    <<"on">> -> Next(livery_req:set_meta(feature, on, Req));
    _        -> Next(Req)
end.
```

## See also

- Reference: `livery_req`
- Reference: `livery_ext`
- Guide: [Extract a bearer token](bearer-tokens.md)
