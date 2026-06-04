# How to compress responses

## Problem

Your responses are bigger than they need to be on the wire, and you
would like them gzipped or deflated whenever the client can handle
it. The catch: you do not want to reach into every handler to make
that happen.

## Solution

Add `livery_compress` to the stack. gzip and deflate are built in:

```erlang
Stack = [
    {livery_compress, #{}}
    %% ... handler
].
```

It reads the request `Accept-Encoding`, picks a codec the client
accepts, compresses the body, and sets `Content-Encoding` along with
`Vary: Accept-Encoding`. A client that sends no `Accept-Encoding`, or
asks only for codings you do not have, simply gets the response
uncompressed. So every HTTP client keeps working: the ones that
advertise gzip decode it transparently, and the rest receive
identity.

## What gets compressed

Livery is selective on purpose. It compresses `{full, _}` bodies of
at least `min_size` bytes and `{chunked, _}` streams, as long as the
`Content-Type` is compressible and there is no `Content-Encoding`
already. SSE, file, empty, and upgrade responses pass through
untouched.

```erlang
{livery_compress, #{
    min_size => 1024,                       %% default; full bodies only
    types => [<<"text/">>, <<"application/json">>]  %% compressible prefixes
}}
```

`Content-Type` matching is case-insensitive and ignores parameters, so
`Application/JSON; charset=utf-8` is compressed.

## Negotiation and server preference

A coding is acceptable when its `Accept-Encoding` q-value is above
zero (`q=0` is a refusal). Among the codings the client accepts, the
SERVER picks which one to use, following the order of the codec list;
the client q-weights act only as an accept-or-reject filter, not a
ranking. You control the order with `codecs`:

```erlang
{livery_compress, #{codecs => [livery_codec_gzip]}}   %% gzip only
```

## Adding more codecs

`livery_compress` negotiates over `livery_codec:registered()`, which
is `[livery_codec_gzip, livery_codec_deflate]` plus any codec a
separate app has registered. To add one, write a module that
implements the `livery_codec` behaviour and call
`livery_codec:register(Module)` when your app starts; from then on it
joins the negotiation automatically (think of a future
`livery_brotli` advertising `br`). The built-ins are always there and
registration can never displace them.

## See also

- Reference: `livery_compress`, `livery_codec`, `livery_codec_gzip`,
  `livery_codec_deflate`
- Recipe: [Enable CORS](enable-cors.md)
- Recipe: [Set security headers](set-security-headers.md)
