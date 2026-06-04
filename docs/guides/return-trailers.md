# How to return trailers

## Problem

Sometimes you only know a value once the body is fully out the door:
a checksum, a final status, a row count. Trailers let you send those
headers after the body (HTTP/1.1 chunked-trailers, HTTP/2 and HTTP/3
trailer frames), and that is what this guide covers.

## Solution

```erlang
fetch(_Req) ->
    Resp = livery_resp:text(200, payload()),
    livery_resp:with_trailers([{<<"x-checksum">>, checksum()}], Resp).
```

`livery_resp:with_trailers/2` accepts:

- a list of `{Name, Value}` pairs, computed up front
- a fun `fun() -> [{Name, Value}]` that runs lazily once the body is
  out, which is exactly what you want when the trailer depends on
  bytes you have not produced yet

```erlang
livery_resp:with_trailers(
    fun() -> [{<<"x-checksum">>, final_hash()}] end,
    livery_resp:stream(200, [], Producer)).
```

## Capability gate

HTTP/2 and HTTP/3 always support trailers. HTTP/1.1 needs chunked
transfer encoding for them, but you do not have to wire that up: the
H1 adapter promotes to chunked automatically as soon as trailers are
present. If your code needs to branch on the protocol, check the
adapter's capabilities map (`c:livery_adapter:capabilities/1`).

## See also

- Reference: `livery_resp`
- Reference: `livery_adapter`
