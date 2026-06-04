# How to cancel work when the client disconnects

## Problem

A request kicks off expensive work: an LLM inference, a long query,
a heavy report. Then the client gives up and disconnects halfway
through. You would rather stop that work right away than keep
burning resources to produce an answer nobody will read.

## Solution

Livery signals the request handler when the client resets the stream
or closes the connection, across HTTP/1.1, HTTP/2, and HTTP/3. There
are two ways to react, depending on how your handler is shaped.

### Streaming handler in a receive loop

A producer that streams tokens already loops on its data source. It
also matches the disconnect message, and stops when `Emit` reports a
failed send:

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

`{livery_disconnect, _, _}` is delivered to the handler's process; the
`Emit` error return is a second backstop. Chunked, SSE, and NDJSON
producers all propagate the send error now, so returning `{error, _}`
from the producer also stops the terminal write.

### Blocking handler

A handler that blocks in a NIF cannot loop. Register a cancel
callback; Livery runs it in a separate process the moment the client
disconnects, so the NIF is signalled even though the handler is busy:

```erlang
complete(Req) ->
    {ok, InferRef} = my_llm:new(),
    ok = livery_req:on_disconnect(Req, fun() -> my_llm:cancel(InferRef) end),
    livery_resp:json(200, my_llm:infer_blocking(InferRef, prompt(Req))).
```

`on_disconnect/2` returns immediately. The callback runs **at most
once**, **only on a real disconnect** (never on normal completion),
and on the test adapter it is a no-op (handler unit tests are
unaffected).

## Notes

- Default is signal-only: Livery does not kill your handler. It runs
  any cleanup it likes, then returns. A handler that ignores the
  signal simply keeps running.
- HTTP/1.1 is half-duplex. A disconnect is detected when the
  connection closes (via the connection monitor) or when a send
  fails; a paused streaming response that never sends again may not
  notice until the connection drops. H2 and H3 multiplex, so a
  reset/close is detected promptly.
- `livery_req:disconnect_tag/0` returns the message tag
  (`livery_disconnect`) for guard-style matching.

## See also

- Reference: `livery_req` (`on_disconnect/2`), `livery_resp`
- Guide: [Return a streaming response](stream-chunked.md),
  [Serve MCP tools](serve-mcp-tools.md)
