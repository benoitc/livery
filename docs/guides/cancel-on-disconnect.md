# How to cancel work when the client disconnects

Some requests start expensive work (an LLM inference, a long query).
You need this when the client disconnects halfway: rather than finish
the work for nobody, you want to stop it. Livery tells the request
handler when the client resets the stream or closes the connection,
on HTTP/1.1, HTTP/2 and HTTP/3. You can react in two ways, depending
on how your handler is written.

## React in a streaming receive loop

A producer that streams tokens already loops over its data source.
Have it also match the disconnect message, and stop when `Emit`
reports that a send failed:

```erlang
chat(Req) ->
    {ok, InferRef} = my_llm:start(prompt(Req)),   %% streams {token, InferRef, T}
    livery_resp:sse(200, fun(Emit) -> stream(Emit, InferRef) end).

stream(Emit, InferRef) ->
    receive
        {token, InferRef, T} ->
            case Emit(#{data => T}) of
                ok         -> stream(Emit, InferRef);
                {error, _} -> my_llm:cancel(InferRef)   %% send failed: client gone
            end;
        {done, InferRef} ->
            ok;
        {livery_disconnect, _Ref, _Reason} ->            %% explicit disconnect
            my_llm:cancel(InferRef)
    end.
```

`{livery_disconnect, _, _}` arrives in the handler's process; the
error returned by `Emit` is a second safety net. Chunked, SSE and
NDJSON producers all pass the send error back, so returning
`{error, _}` from the producer also skips the last write that would
end the stream.

## React from a blocking handler

A handler that blocks in a NIF cannot loop. Register a cancel
callback instead: Livery runs it in a separate process as soon as the
client disconnects, so the NIF gets the signal even while the handler
is busy:

```erlang
complete(Req) ->
    {ok, InferRef} = my_llm:new(),
    ok = livery_req:on_disconnect(Req, fun() -> my_llm:cancel(InferRef) end),
    livery_resp:json(200, my_llm:infer_blocking(InferRef, prompt(Req))).
```

`on_disconnect/2` returns immediately. The callback runs **at most
once**, **only on a real disconnect** (never on normal completion),
and does nothing on the test adapter (your handler unit tests are
not affected).

## Notes

- By default Livery only signals: it does not kill your handler. The
  handler runs whatever cleanup it needs, then returns. A handler that
  ignores the signal keeps running.
- HTTP/1.1 is half-duplex. Livery sees a disconnect when the
  connection closes (through the connection monitor) or when a send
  fails; a streaming response that pauses and never sends again may
  not notice until the connection drops. H2 and H3 multiplex streams
  over one connection, so a reset or close is seen right away.
- `livery_req:disconnect_tag/0` returns the message tag
  (`livery_disconnect`) for guard-style matching.

## See also

- Reference: `livery_req` (`on_disconnect/2`), `livery_resp`
- Guide: [Return a streaming response](stream-chunked.md),
  [Serve MCP tools](serve-mcp-tools.md)
