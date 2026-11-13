# How to add HTTP caching (ETag and Cache-Control)

You want clients and CDNs to check cheaply that their copy is still
good (revalidate): they keep a copy, send `If-None-Match`, and get a
`304 Not Modified` with no body when nothing changed. You also want a
way to set `Cache-Control`. Add `livery_etag` to the
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
that don't already have one. A handler can set its own (kept on
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

Put `livery_etag` outside `livery_compress` (earlier in the stack
list) so the ETag covers the bytes actually sent:

```erlang
Stack = [{livery_etag, #{}}, {livery_compress, #{}} | Rest].
```

If you place it inside compression, the ETag is computed from the
uncompressed body. `livery_compress` then turns it into a weak ETag
(`W/"..."`) on every compressed response, because a strong ETag must
change when the bytes change (RFC 9110 section 8.8.1), and gzip changes
them. The same happens to an ETag your handler sets with
`livery_resp:with_etag/2`. Revalidation still works: `If-None-Match`
compares weakly.

## Notes

- `If-None-Match: *` matches any current representation; weak
  comparison (RFC 9110) is used, so `W/"x"` and `"x"` match.
- The `304` has no body and drops the `content-*` headers, but keeps
  `ETag`, `Cache-Control` and `Vary`.
- Only `GET`/`HEAD` are handled; preconditions on unsafe methods
  (`412`) are not.

## See also

- Reference: `livery_etag`, `livery_resp` (`with_etag/2`,
  `with_cache_control/2`)
- Guide: [Compress responses](compress-responses.md)
