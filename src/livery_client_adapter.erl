-module(livery_client_adapter).
-moduledoc """
Behaviour for an outbound HTTP transport, the client-side dual of
`livery_adapter`.

An adapter owns the wire: it takes a `livery_client:request()` and
produces a `livery_client:response()` (or an error). The composable
layers (timeout, retry, concurrency, circuit breaker) sit above it and
do not care which transport runs underneath. The default adapter is
`livery_client_hackney` (HTTP/1.1, HTTP/2, and HTTP/3 via hackney);
write your own to front a different client.

## Callbacks

- `request(Request, Opts) -> {ok, Response} | {error, term()}` - send
  one request. The adapter owns its connections and pooling.
- `read(Reader, Timeout) -> {ok, Data, Reader} | {done, Reader} |
  {error, term()}` - *optional*; pull the next chunk of a streamed
  response body. Only adapters that return a `{stream, Reader}` response
  body implement it.
""".

-callback request(livery_client:request(), map()) ->
    {ok, livery_client:response()} | {error, term()}.

-callback read(term(), timeout()) ->
    {ok, binary(), term()} | {done, term()} | {error, term()}.

-optional_callbacks([read/2]).
