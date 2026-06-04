# How to serve a file

## Problem

You have a file on disk and you want to send it back as the
response. Maybe it is a stylesheet, a PDF, a download. You do not
want to read the whole thing into memory first, especially when it
is large. Livery can stream it straight off the disk for you.

## Solution

```erlang
livery_resp:file(200, <<"/var/www/index.html">>).
```

That is all. Livery streams the file in 64 KiB chunks straight to
the wire on H1, H2, and H3, and sets `Content-Length` from the file
size unless your handler already set it.

One thing it will not do for you is guess the content type, so set
it yourself:

```erlang
fun(_Req) ->
    R = livery_resp:file(200, <<"/var/www/app.css">>),
    livery_resp:with_header(<<"content-type">>, <<"text/css">>, R)
end.
```

## Serve a byte range

Sometimes you only want part of the file, say to resume a download.
Pass `{Offset, Length}` to send a slice. `Length` may be `eof` to
read to the end. Livery adds a `Content-Range` header and the right
`Content-Length` for the slice:

```erlang
%% bytes 1024-2047 of the file
livery_resp:file(206, Path, {1024, 1024}).

%% from byte 1024 to the end
livery_resp:file(206, Path, {1024, eof}).
```

Remember to set the status to `206` yourself when you serve a
partial range.

## Security: never pass unsanitised paths

Here is the catch. `livery_resp:file/2,3` serves exactly the path
you give it and nothing more; it does not confine it to a directory.
So if you build the path from request data (a path parameter, a
query string, a header), an attacker can slip in `..` to climb out
of your intended root and read arbitrary files.

The fix is to confine the path yourself before serving:

```erlang
serve_asset(Req) ->
    Name = livery_req:binding(<<"name">>, Req),
    Root = <<"/var/www/assets">>,
    Path = filename:join(Root, Name),
    %% Reject anything that resolves outside Root.
    Safe = filename:absname(Path),
    case binary:match(filename:absname(Path), filename:absname(Root)) of
        {0, _} -> livery_resp:file(200, Safe);
        _      -> livery_resp:text(403, <<"forbidden">>)
    end.
```

And when you can, prefer an allowlist of known filenames. It is the
simplest thing that cannot go wrong.

## Error handling

| Situation | Response |
|---|---|
| File does not exist | `404` |
| Range starts past the end of the file | `416` |
| Path is a directory or unreadable | stream reset |

## See also

- Reference: `livery_resp`, `livery`
- Concept: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
