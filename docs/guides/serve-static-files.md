# How to serve static files

`livery_static:handler/1,2` serves a directory of files (assets, a
built single-page app, downloads) over HTTP, with the right
`Content-Type`, conditional GET (a `304` when the client already has
the file), and `Range` support, and without exposing anything outside
the directory. You need it when you want to serve a folder of files
rather than write a handler per file.

## Mount it on a wildcard route

Mount the handler on a router wildcard route. The `*path` segment
takes the rest of the URL, and the handler turns it into a file under
the root:

```erlang
Router = livery_router:add(
    '_', <<"/assets/*path">>, livery_static:handler("priv/assets"), #{}, Router0
).
```

`GET /assets/css/app.css` serves `priv/assets/css/app.css` with
`Content-Type: text/css`, an `ETag`, and (if the client sends `Range`)
partial content.

## Serve it without the router

If you are not using the router, configure a `prefix` to strip from the
request path:

```erlang
livery:start_listener(livery_h1, #{
    port => 8080,
    handler => livery_static:handler("public", #{prefix => <<"/">>})
}).
```

`livery_static:handler/2` returns a handler, not a middleware, so it
goes under `handler`, not in the middleware stack.

## Options

```erlang
livery_static:handler("priv/assets", #{
    binding => <<"path">>,                 %% router binding name (default)
    prefix => <<"/assets/">>,              %% fallback when there is no binding
    index => <<"index.html">>,             %% served for a directory; false to disable
    cache_control => [{max_age, 3600}, public],  %% optional Cache-Control
    etag => true,                          %% weak ETag from size+mtime (default)
    range => true                          %% honor Range requests (default)
}).
```

## Behaviour

- `Content-Type` comes from the file extension (text types get
  `; charset=utf-8`), and is `application/octet-stream` when the
  extension is unknown.
- A weak `ETag` (`W/"size-mtime"`) is sent; a matching
  `If-None-Match` returns `304 Not Modified`.
- `Range: bytes=...` returns `206 Partial Content`; an unsatisfiable
  range returns `416` with `Content-Range: bytes */<size>`.
- Responses carry `Last-Modified`. A `Range` with `If-Range` is served
  only when its date matches `Last-Modified` exactly; an `If-Range`
  with an ETag gets the whole file, since these ETags are weak and the
  check needs a strong one (RFC 9110 section 13.1.5).
- `HEAD` returns headers (including `Content-Length`) with no body.
- Only `GET`/`HEAD` are served; other methods get `405` with `Allow`.
- A directory request serves `index` if present, else `404` (no
  directory listing).

## Notes

- The sub-path is percent-decoded and then checked: any `..` segment,
  absolute path, control byte, or bad escape is refused with `404`, so a
  request can never reach a file outside the root.
- Only regular files are served (directories and symlinks get `404`),
  so a symlink inside the root cannot be used to get out of it.

## See also

- Reference: `livery_static`, `livery_resp` (`file/2,3`)
- Guide: [Add HTTP caching](http-caching.md)
- Guide: [Serve a file](serve-a-file.md)
