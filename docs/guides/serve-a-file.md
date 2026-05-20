# How to serve a file

## Problem

You want to send a file from disk as the response body without
reading it all into memory first.

## Solution

```erlang
livery_resp:file(200, <<"/var/www/index.html">>).
```

Livery streams the file in 64 KiB chunks straight to the wire on
H1, H2, and H3. `Content-Length` is set from the file size unless
your handler already set it.

Set the content type yourself; Livery does not guess it:

```erlang
fun(_Req) ->
    R = livery_resp:file(200, <<"/var/www/app.css">>),
    livery_resp:with_header(<<"content-type">>, <<"text/css">>, R)
end.
```

## Serve a byte range

Pass `{Offset, Length}` to send a slice. `Length` may be `eof` to
read to the end of the file. Livery adds a `Content-Range` header
and `Content-Length` for the slice:

```erlang
%% bytes 1024-2047 of the file
livery_resp:file(206, Path, {1024, 1024}).

%% from byte 1024 to the end
livery_resp:file(206, Path, {1024, eof}).
```

Set the status to `206` yourself when you serve a partial range.

## Error handling

| Situation | Response |
|---|---|
| File does not exist | `404` |
| Range starts past the end of the file | `416` |
| Path is a directory or unreadable | stream reset |

## See also

- Reference: `livery_resp`, `livery`
- Concept: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
