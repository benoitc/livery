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
identity. A client that refuses unencoded content (`identity;q=0`, or
`*;q=0` without `identity`) and accepts none of the codecs you have gets
`406 Not Acceptable`.

A compressed response with a strong `ETag` gets a weak one instead
(`"v1"` becomes `W/"v1"`): the gzip bytes are not the bytes the tag was
made for (RFC 9110 section 8.8.1). Put `livery_etag` before
`livery_compress` in the stack if you want a strong ETag computed over
the compressed bytes. See [Add HTTP caching](http-caching.md).

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

The client's q-values decide (RFC 9110 section 12.5.3): the codec with
the highest q above zero wins, and `q=0` refuses one. When the client
gives several the same q, the order of the codec list breaks the tie.
Control that order, or limit the codecs, with `codecs`:

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
