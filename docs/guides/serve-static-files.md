# How to serve static files

## Problem

You want to serve a directory of files (assets, a built SPA, downloads)
over HTTP, with correct `Content-Type`, conditional GET, and `Range`
support - without exposing anything outside the directory.

## Solution

Mount `livery_static:handler/1,2` on a router WILDCARD route. The `*path`
segment captures the rest of the URL, which the handler maps to a file
under the root:

```erlang
Router = livery_router:add(
    '_', <<"/assets/*path">>, livery_static:handler("priv/assets"), #{}, Router0
).
```

`GET /assets/css/app.css` serves `priv/assets/css/app.css` with
`Content-Type: text/css`, an `ETag`, and (if the client sends `Range`)
partial content.

## Without the router

If you are not using the router, configure a `prefix` to strip from the
request path:

```erlang
{livery_static, never}  %% NB: it is a handler, not middleware
%% as a service handler:
livery:start_listener(h1, #{
    port => 8080,
    handler => livery_static:handler("public", #{prefix => <<"/">>})
}).
```

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

## Behavior

- `Content-Type` is inferred from the file extension (text types get
  `; charset=utf-8`), defaulting to `application/octet-stream`.
- A weak `ETag` (`W/"size-mtime"`) is emitted; a matching
  `If-None-Match` returns `304 Not Modified`.
- `Range: bytes=...` returns `206 Partial Content`; an unsatisfiable
  range returns `416`.
- `HEAD` returns headers (including `Content-Length`) with no body.
- Only `GET`/`HEAD` are served; other methods get `405` with `Allow`.
- A directory request serves `index` if present, else `404` (no
  directory listing).

## Security

The sub-path is percent-decoded and then confined: any `..` segment,
absolute path, control byte, or bad escape is rejected with `404`, so a
request can never traverse out of the root. Only regular files are
served - directories and symlinks yield `404` - so a symlink inside the
root cannot be used to escape it.

## See also

- Reference: `livery_static`, `livery_resp` (`file/2,3`)
- Recipe: [Add HTTP caching](http-caching.md)
- Recipe: [Serve a file](serve-a-file.md)
