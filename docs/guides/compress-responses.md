# How to compress responses

`livery_compress` is a middleware that compresses response bodies when
the client supports it. You need it when you want gzip or deflate
without touching every handler.

## Add it to the stack

gzip and deflate are built in:

```erlang
Stack = [
    {livery_compress, #{}}
    %% ... handler
].
```

It reads the request `Accept-Encoding`, picks a codec the client
accepts, compresses the response body, and sets `Content-Encoding` plus
`Vary: Accept-Encoding`. A client that sends no `Accept-Encoding` (or
none the server has) gets the response uncompressed, so any HTTP client
works: those that advertise gzip decode it transparently, the rest get
identity.

## Control what gets compressed

Eligible responses are `{full, _}` bodies at least `min_size` bytes and
`{chunked, _}` streams, with a compressible `Content-Type` and no
existing `Content-Encoding`. SSE, file, empty, and upgrade responses
pass through untouched.

```erlang
{livery_compress, #{
    min_size => 1024,                       %% default; full bodies only
    types => [<<"text/">>, <<"application/json">>]  %% compressible prefixes
}}
```

`Content-Type` matching is case-insensitive and ignores parameters, so
`Application/JSON; charset=utf-8` is compressed.

## Set server preference

A coding is acceptable when its `Accept-Encoding` q-value is greater
than zero (`q=0` rejects). Among acceptable codings the SERVER decides
which to use, in the order of the codec list; client q-weights are only
an accept/reject filter. Control the order with `codecs`:

```erlang
{livery_compress, #{codecs => [livery_codec_gzip]}}   %% gzip only
```

## Add more codecs

`livery_compress` negotiates over `livery_codec:registered()`, which is
`[livery_codec_gzip, livery_codec_deflate]` plus any codec a separate
app registered. A codec app implements the `livery_codec` behaviour and
calls `livery_codec:register(Module)` at its own start; it is then
negotiated automatically (e.g. a future `livery_brotli` advertising
`br`). The built-ins are always present and cannot be displaced by
registration.

## See also

- Reference: `livery_compress`, `livery_codec`, `livery_codec_gzip`,
  `livery_codec_deflate`
- Guide: [Enable CORS](enable-cors.md)
- Guide: [Set security headers](set-security-headers.md)
