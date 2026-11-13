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

Header names are matched without regard to case. Both
`<<"Content-Type">>` and `<<"content-type">>` work: Livery lowercases
names when the request comes in, so a lookup only lowercases the name
you pass and compares it as is.

## Read repeated headers

`livery_req:headers_all/2` returns every value for the header, in the
order they arrived. Use it for `Set-Cookie`, `Vary`, and
comma-separated lists like `Accept-Encoding`:

```erlang
Accepts = livery_req:headers_all(<<"accept">>, Req).
```

## Read all headers

```erlang
livery_req:headers(Req)        %% [{Name, Value}] (lowercased names)
livery_req:has_header(<<"x-trace">>, Req)
```

## Read from a middleware

You can also read headers with the extractors:

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
