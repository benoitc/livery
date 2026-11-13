# How to serve a file

`livery_resp:file/2,3` sends a file from disk as the response body,
piece by piece, instead of reading it all into memory first. You need
it for downloads, static assets, or any response that comes from a
file on disk.

## Send a file

```erlang
livery_resp:file(200, <<"/var/www/index.html">>).
```

Livery streams the file in 64 KiB chunks on H1, H2, and H3.
`Content-Length` is set from the file size unless your handler
already set it.

Set the content type yourself; Livery does not guess it:

```erlang
fun(_Req) ->
    R = livery_resp:file(200, <<"/var/www/app.css">>),
    livery_resp:with_header(<<"content-type">>, <<"text/css">>, R)
end.
```

## Serve a byte range

Pass `{Offset, Length}` to send only part of the file. `Length` may be
`eof` to read to the end of the file. Livery adds a `Content-Range` header
and `Content-Length` for the slice. Set the status to `206`
yourself when you serve a partial range:

```erlang
%% bytes 1024-2047 of the file
livery_resp:file(206, Path, {1024, 1024}).

%% from byte 1024 to the end
livery_resp:file(206, Path, {1024, eof}).
```

## Confine paths built from request data

`livery_resp:file/2,3` serves exactly the path you give it; Livery
does not keep it inside a directory. If you build the path from
request data (a path parameter, query string, header), an attacker
can use `..` to step out of the directory you meant and read any
file.

Check the path with `filelib:safe_relative_path/2` before you serve
it. It removes `.` and `..`, follows symbolic links below the root, and
returns `unsafe` when the result would leave the root or when the name
is an absolute path:

```erlang
serve_asset(Req) ->
    Root = "/var/www/assets",
    Name = binary_to_list(livery_req:binding(<<"path">>, Req, <<>>)),
    case filelib:safe_relative_path(Name, Root) of
        unsafe -> livery_resp:text(403, <<"forbidden">>);
        [] -> livery_resp:text(404, <<"not found">>);
        Rel -> livery_resp:file(200, filename:join(Root, Rel))
    end.
```

Do not compare the joined path with the root as a string prefix:
`filename:absname/1` keeps `..` as it is, and a prefix test also lets
through a sibling such as `/var/www/assets-old`.

To serve a whole directory, use `livery_static`, which does these checks
for you (see [Serve static files](serve-static-files.md)). When you can,
accept only file names from a list you know.

## Error handling

| Situation | Response |
|---|---|
| File does not exist | `404` |
| Range starts at or past the end of the file, or the file is empty | `416` with `Content-Range: bytes */<size>` |
| Path is a directory or unreadable | the stream is reset |

## See also

- Reference: `livery_resp`, `livery`
- Concept: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
