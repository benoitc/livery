# How to read headers

## Problem

You need a header value from the request.

## Solution

```erlang
ContentType = livery_req:header(<<"content-type">>, Req),
%% or, with a default:
Accept = livery_req:header(<<"accept">>, Req, <<"*/*">>).
```

Header names are matched case-insensitively. Both
`<<"Content-Type">>` and `<<"content-type">>` work; Livery
lowercases on ingest so lookups are constant-time after that.

## Repeated headers

`livery_req:headers_all/2` returns every value for the header in
wire order. Useful for `Set-Cookie`, `Vary`, comma-separated
lists like `Accept-Encoding`:

```erlang
Accepts = livery_req:headers_all(<<"accept">>, Req).
```

## All headers

```erlang
livery_req:headers(Req)        %% [{Name, Value}] (lowercased names)
livery_req:has_header(<<"x-trace">>, Req)
```

## From a middleware

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
- Recipe: [Extract a bearer token](bearer-tokens.md)
