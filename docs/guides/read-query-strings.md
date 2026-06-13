# How to read query string parameters

`livery_ext:query/2` reads a value from the request URL's query string.
You need it whenever a handler depends on parameters like `?q=...` or
`?page=...`.

## Read a parameter

```erlang
search(Req) ->
    Q = livery_ext:query(<<"q">>, Req),
    Page = livery_ext:query(<<"page">>, Req),
    do_search(Q, Page).
```

`livery_ext:query/2` returns the first value for the key, or
`undefined` if it is missing.

## Apply a default value

Wrap with a fallback:

```erlang
Page = case livery_ext:query(<<"page">>, Req) of
    undefined -> <<"1">>;
    V         -> V
end.
```

## Convert to an integer

`livery_ext:query/2` always returns a binary. Convert at the call
site:

```erlang
PageInt = try binary_to_integer(Page) catch _:_ -> 1 end.
```

## URL-decoded values

Values are URL-decoded:

```erlang
%% /search?q=hello%20world&unit=100%25
<<"hello world">> = livery_ext:query(<<"q">>, Req),
<<"100%">>        = livery_ext:query(<<"unit">>, Req).
```

## Notes

- `livery_ext:query/2` returns only the first value for a repeated
  key. To read all values, call `livery_req:query/1` to get the raw
  query string and parse it yourself, or open an issue if you need
  this in `livery_ext`.

## See also

- Reference: `livery_ext`
- Reference: `livery_req`
