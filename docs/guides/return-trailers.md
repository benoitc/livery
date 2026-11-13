# How to return trailers

Trailers are response headers sent after the body (at the end of a
chunked body on HTTP/1.1, in a final headers frame on HTTP/2 and
HTTP/3). You need them
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
pass a fun instead. Livery calls it once the body has been sent:

```erlang
livery_resp:with_trailers(
    fun() -> [{<<"x-checksum">>, final_hash()}] end,
    livery_resp:stream(200, [], Producer)).
```

## Notes

- Trailers always work on HTTP/2 and HTTP/3. On HTTP/1.1 they need
  chunked transfer encoding, and the H1 adapter switches to it on its
  own when a response has trailers.
- Check the adapter's capabilities map
  (`c:livery_adapter:capabilities/1`) if your code has to behave
  differently per protocol.

## See also

- Reference: `livery_resp`
- Reference: `livery_adapter`
