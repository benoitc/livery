# How to parse form bodies and query strings

## Problem

You need the fields from an `application/x-www-form-urlencoded` request
body, or the parameters from the URL query string.

## Query string

`livery_ext:query/2` pulls a single decoded parameter from the request
URI:

```erlang
search(Req) ->
    Term = livery_ext:query(<<"q">>, Req),     %% percent-decoded, or undefined
    ...
```

## Form body (urlencoded)

If the body is already buffered, `livery_ext:form/1` decodes it
directly. Since adapters stream bodies by default, use `read_form/1,2`,
which drains the stream (bounded) and decodes:

```erlang
submit(Req) ->
    case livery_ext:read_form(Req) of
        {ok, Pairs} ->            %% [{<<"name">>, <<"value">>}, ...]
            Name = proplists:get_value(<<"name">>, Pairs),
            ...;
        {error, not_form} ->
            livery_resp:text(415, <<"expected a form body">>);
        {error, _} ->
            livery_resp:text(400, <<"bad form body">>)
    end.
```

The `Content-Type` check is case-insensitive and tolerates parameters
(`Application/X-WWW-Form-Urlencoded; charset=utf-8`). Cap the body with
`#{max_size => Bytes}` (default 1 MiB) and the per-read wait with
`#{timeout => Ms}`.

Decoding handles `%XX` escapes and `+` as space. A malformed escape
(`%ZZ`) is kept verbatim rather than failing the whole body, matching
`form/1`.

## See also

- Reference: `livery_ext`
- Recipe: [Handle file uploads](handle-file-uploads.md)
- Recipe: [Read query strings](read-query-strings.md)
