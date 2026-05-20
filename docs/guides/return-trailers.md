# How to return trailers

## Problem

You need to emit response trailers (HTTP/1.1 chunked-trailers,
HTTP/2/3 trailer frames) after the body.

## Solution

```erlang
fetch(_Req) ->
    Resp = livery_resp:text(200, payload()),
    livery_resp:with_trailers([{<<"x-checksum">>, checksum()}], Resp).
```

`livery_resp:with_trailers/2` accepts:

- a list of `{Name, Value}` pairs, computed up front
- a fun `fun() -> [{Name, Value}]` evaluated lazily after the body
  has been emitted (useful when the trailer depends on bytes that
  have not been produced yet)

```erlang
livery_resp:with_trailers(
    fun() -> [{<<"x-checksum">>, final_hash()}] end,
    livery_resp:stream(200, [], Producer)).
```

## Capability gate

Trailers are always supported on HTTP/2 and HTTP/3. On HTTP/1.1
they require chunked transfer encoding; the H1 adapter
auto-promotes when trailers are present. Check the adapter's
capabilities map (`c:livery_adapter:capabilities/1`) if your code
must adapt by protocol.

## See also

- Reference: `livery_resp`
- Reference: `livery_adapter`
