# How to add HTTP caching (ETag and Cache-Control)

## Problem

You would like clients and CDNs to stop re-downloading things that
have not changed. The HTTP way to do this is cheap revalidation: a
client keeps its copy, sends `If-None-Match` on the next request, and
gets a bodyless `304 Not Modified` when nothing has moved. While you
are at it, you also want to say how long a response may be cached with
`Cache-Control`.

## Solution

Drop `livery_etag` into the stack. It attaches a strong ETag to
cacheable `GET`/`HEAD` responses and, when a client comes back with a
matching `If-None-Match`, answers `304` for you:

```erlang
Stack = [
    {livery_etag, #{}}
    %% ... handler
].
```

The first request gets a `200` with an `ETag`; a later request that
echoes that ETag back in `If-None-Match` gets a `304` and no body.
That is the whole loop.

## Setting your own ETag and Cache-Control

By default the middleware computes an ETag for you, from `{full, _}`
bodies that don't already have one. But you are always free to set
your own, and it is respected on any body type, including `file` and
`chunked`:

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

## Options

```erlang
{livery_etag, #{
    auto => true,        %% auto-hash full bodies without an ETag (default)
    weak => false,       %% auto ETags are strong "..."; true emits W/"..."
    statuses => [200]    %% statuses eligible for ETag/304 (default [200])
}}
```

Flip `auto => false` and the middleware steps back entirely: it only
acts on ETags you set yourself.

## Placement relative to compression

Order matters here. Put `livery_etag` OUTSIDE `livery_compress`
(earlier in the stack list) so the ETag is computed over the bytes
that actually go out on the wire:

```erlang
Stack = [{livery_etag, #{}}, {livery_compress, #{}} | Rest].
```

If you place it inside compression instead, the ETag ends up computed
from the uncompressed body. That can still work, but then you must
lean on `Vary: Accept-Encoding` (which `livery_compress` already sets)
to keep caches from mixing up the per-encoding variants.

## Notes

- `If-None-Match: *` matches any current representation; weak comparison
  (RFC 9110) is used, so `W/"x"` and `"x"` match.
- The `304` is bodyless and drops `content-*` headers while preserving
  `ETag`, `Cache-Control`, and `Vary`.
- Only `GET`/`HEAD` are handled; unsafe-method preconditions (`412`) are
  out of scope.

## See also

- Reference: `livery_etag`, `livery_resp` (`with_etag/2`,
  `with_cache_control/2`)
- Recipe: [Compress responses](compress-responses.md)
