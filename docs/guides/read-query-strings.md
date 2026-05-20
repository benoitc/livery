# How to read query string parameters

## Problem

You need a query string value from the request URL.

## Solution

```erlang
search(Req) ->
    Q = livery_ext:query(<<"q">>, Req),
    Page = livery_ext:query(<<"page">>, Req),
    do_search(Q, Page).
```

`livery_ext:query/2` returns the first value for the key, or
`undefined` if it is missing.

## Default values

Wrap with a fallback:

```erlang
Page = case livery_ext:query(<<"page">>, Req) of
    undefined -> <<"1">>;
    V         -> V
end.
```

## Integer values

`livery_ext:query/2` always returns a binary. Convert at the call
site:

```erlang
PageInt = try binary_to_integer(Page) catch _:_ -> 1 end.
```

## URL-decoded

Values are URL-decoded:

```erlang
%% /search?q=hello%20world&unit=100%25
<<"hello world">> = livery_ext:query(<<"q">>, Req),
<<"100%">>        = livery_ext:query(<<"unit">>, Req).
```

## Multiple values for the same key

Today `livery_ext:query/2` returns only the first. To read all
values, call `livery_req:query/1` to get the raw query string and
parse it yourself, or open an issue if you need this in `livery_ext`.

## See also

- Reference: `livery_ext`
- Reference: `livery_req`
