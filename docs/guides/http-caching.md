# How to add HTTP caching (ETag and Cache-Control)

You want clients and CDNs to revalidate cheaply: hold a copy, send
`If-None-Match`, and get a bodyless `304 Not Modified` when nothing
changed, plus a way to set `Cache-Control`. Add `livery_etag` to the
stack: it gives a strong ETag to cacheable `GET`/`HEAD` responses and
answers `304` on a matching `If-None-Match`.

## Add it to the stack

```erlang
Stack = [
    {livery_etag, #{}}
    %% ... handler
].
```

A first request returns `200` with an `ETag`; a later request that
sends that ETag in `If-None-Match` gets a `304` with no body.

## Set your own ETag and Cache-Control

The middleware computes an ETag automatically from `{full, _}` bodies
that don't already have one. A handler can set its own (respected on
any body type, including `file`/`chunked`):

```erlang
show(Req) ->
    Resp = livery_resp:json(200, render(Req)),
    R1 = livery_resp:with_etag(<<"post-42-v3">>, Resp),     %% -> ETag: "post-42-v3"
    livery_resp:with_cache_control([public, {max_age, 300}], R1).
```

`with_cache_control/2` takes a verbatim binary or a directive list
(`no_cache`, `no_store`, `public`, `private`, `immutable`,
`must_revalidate`, `proxy_revalidate`, `no_transform`, `{max_age, N}`,
`{s_maxage, N}`, `{stale_while_revalidate, N}`, `{stale_if_error, N}`).

## Tune the options

```erlang
{livery_etag, #{
    auto => true,        %% auto-hash full bodies without an ETag (default)
    weak => false,       %% auto ETags are strong "..."; true emits W/"..."
    statuses => [200]    %% statuses eligible for ETag/304 (default [200])
}}
```

With `auto => false` the middleware only acts on handler-set ETags.

## Place it relative to compression

Put `livery_etag` OUTSIDE `livery_compress` (earlier in the stack
list) so the ETag covers the bytes actually sent on the wire:

```erlang
Stack = [{livery_etag, #{}}, {livery_compress, #{}} | Rest].
```

If you place it inside compression, the ETag is computed from the
uncompressed body; rely on `Vary: Accept-Encoding` (which
`livery_compress` already sets) so caches keep per-encoding variants
distinct.

## Notes

- `If-None-Match: *` matches any current representation; weak
  comparison (RFC 9110) is used, so `W/"x"` and `"x"` match.
- The `304` is bodyless and drops `content-*` headers while
  preserving `ETag`, `Cache-Control`, and `Vary`.
- Only `GET`/`HEAD` are handled; unsafe-method preconditions (`412`)
  are out of scope.

## See also

- Reference: `livery_etag`, `livery_resp` (`with_etag/2`,
  `with_cache_control/2`)
- Guide: [Compress responses](compress-responses.md)
