# How to read query string parameters

## Problem

The interesting bits of a request often hang off the URL after the
`?`: a search term, a page number, a filter. You want those values,
already decoded, without parsing the query string by hand.

## Solution

```erlang
search(Req) ->
    Q = livery_ext:query(<<"q">>, Req),
    Page = livery_ext:query(<<"page">>, Req),
    do_search(Q, Page).
```

`livery_ext:query/2` gives you the first value for the key, or
`undefined` when it is not there.

## Default values

When a parameter is optional, wrap it with a fallback:

```erlang
Page = case livery_ext:query(<<"page">>, Req) of
    undefined -> <<"1">>;
    V         -> V
end.
```

## Integer values

`livery_ext:query/2` always hands back a binary, so do the conversion
yourself at the call site and pick a sensible default if it fails:

```erlang
PageInt = try binary_to_integer(Page) catch _:_ -> 1 end.
```

## URL-decoded

You get values already URL-decoded, no extra step needed:

```erlang
%% /search?q=hello%20world&unit=100%25
<<"hello world">> = livery_ext:query(<<"q">>, Req),
<<"100%">>        = livery_ext:query(<<"unit">>, Req).
```

## Multiple values for the same key

For now `livery_ext:query/2` only gives you the first one. If you need
them all, grab the raw query string with `livery_req:query/1` and parse
it yourself, or open an issue if you would like this built into
`livery_ext`.

## See also

- Reference: `livery_ext`
- Reference: `livery_req`
