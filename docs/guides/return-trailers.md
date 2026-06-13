# How to return trailers

Trailers are response headers sent after the body (HTTP/1.1
chunked-trailers, HTTP/2 and HTTP/3 trailer frames). You need them
when a value is only known once the body has been produced, such as
a checksum over the bytes you streamed.

## Attach trailers to a response

Pass a list of `{Name, Value}` pairs to
`livery_resp:with_trailers/2`:

```erlang
fetch(_Req) ->
    Resp = livery_resp:text(200, payload()),
    livery_resp:with_trailers([{<<"x-checksum">>, checksum()}], Resp).
```

## Compute a trailer lazily

When the trailer depends on bytes that have not been produced yet,
pass a fun instead. Livery evaluates it after the body has been
emitted:

```erlang
livery_resp:with_trailers(
    fun() -> [{<<"x-checksum">>, final_hash()}] end,
    livery_resp:stream(200, [], Producer)).
```

## Notes

- Trailers are always supported on HTTP/2 and HTTP/3. On HTTP/1.1
  they require chunked transfer encoding; the H1 adapter
  auto-promotes when trailers are present.
- Check the adapter's capabilities map
  (`c:livery_adapter:capabilities/1`) if your code must adapt by
  protocol.

## See also

- Reference: `livery_resp`
- Reference: `livery_adapter`
