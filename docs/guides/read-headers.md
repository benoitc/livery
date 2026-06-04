# How to read headers

## Problem

You want to peek at a header on the incoming request, maybe the
`Content-Type`, an `Accept`, or some custom flag, and act on it. It is
about as everyday as it gets, so here is the short version.

## Solution

```erlang
ContentType = livery_req:header(<<"content-type">>, Req),
%% or, with a default:
Accept = livery_req:header(<<"accept">>, Req, <<"*/*">>).
```

Header names are matched case-insensitively, so both
`<<"Content-Type">>` and `<<"content-type">>` work the same. Livery
lowercases everything on the way in, which keeps lookups
constant-time afterwards.

## Repeated headers

Some headers show up more than once. `livery_req:headers_all/2` gives
you every value in wire order, which is just what you want for
`Set-Cookie`, `Vary`, or comma-separated lists like `Accept-Encoding`:

```erlang
Accepts = livery_req:headers_all(<<"accept">>, Req).
```

## All headers

```erlang
livery_req:headers(Req)        %% [{Name, Value}] (lowercased names)
livery_req:has_header(<<"x-trace">>, Req)
```

## From a middleware

From inside middleware you can read headers through extractors just as
easily:

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
