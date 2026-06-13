# How to serve a file

`livery_resp:file/2,3` sends a file from disk as the response body,
streaming it straight to the wire instead of reading it all into
memory. You need it for downloads, static assets, or any response
backed by a file on disk.

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

Pass `{Offset, Length}` to send a slice. `Length` may be `eof` to
read to the end of the file. Livery adds a `Content-Range` header
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
does not confine it to a directory. If you build the path from
request data (a path parameter, query string, header), an attacker
can use `..` to escape your intended root and read arbitrary files.

Confine it yourself before serving:

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

Prefer an allowlist of known filenames where you can.

## Error handling

| Situation | Response |
|---|---|
| File does not exist | `404` |
| Range starts past the end of the file | `416` |
| Path is a directory or unreadable | stream reset |

## See also

- Reference: `livery_resp`, `livery`
- Concept: [Streaming and backpressure](../concepts/streaming-and-backpressure.md)
