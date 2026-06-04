# How to parse form bodies and query strings

## Problem

A classic HTML form just posted to your route, or a link carried a few
parameters in its query string, and now you want those values as plain
binaries you can work with. That is exactly what this guide is for.

## Query string

`livery_ext:query/2` pulls one decoded parameter straight out of the
request URI:

```erlang
search(Req) ->
    Term = livery_ext:query(<<"q">>, Req),     %% percent-decoded, or undefined
    ...
```

## Form body (urlencoded)

If the body is already buffered, `livery_ext:form/1` decodes it on the
spot. But adapters stream bodies by default, so most of the time you
want `read_form/1,2`: it drains the stream for you (within bounds) and
then decodes:

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

The `Content-Type` check is case-insensitive and forgiving about extra
parameters, so `Application/X-WWW-Form-Urlencoded; charset=utf-8` is
fine. Cap the body with `#{max_size => Bytes}` (1 MiB by default) and
the per-read wait with `#{timeout => Ms}`.

Decoding handles `%XX` escapes and reads `+` as a space. A malformed
escape like `%ZZ` is kept as-is rather than blowing up the whole body,
just like `form/1` does.

## See also

- Reference: `livery_ext`
- Recipe: [Handle file uploads](handle-file-uploads.md)
- Recipe: [Read query strings](read-query-strings.md)
