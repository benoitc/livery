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
- `stream(Request, Opts, StreamOpts) -> {ok, Ref} | {error, term()}` -
  *optional*; drive the request in a background process owned by the
  adapter and deliver the response to `StreamOpts`'s `stream_to` pid as
  ordered `{livery_response, Ref, _}` messages (`{status, Status,
  Headers}`, `{chunk, Binary}`, `done`, `{error, Reason}`). `StreamOpts`
  carries `stream_to` (the recipient) and `flow` (`auto` to push as fast
  as the wire allows, `manual` to send one chunk per `stream_next/1`).
  `Ref` is opaque and identifies the stream for `stream_next/1` and
  `stop_stream/1`.
- `stream_next(Ref) -> ok | {error, term()}` - *optional*; under `flow =>
  manual`, ask for one more body chunk.
- `stop_stream(Ref) -> ok` - *optional*; cancel a push stream and release
  its connection.
- `adopt(Reader, Owner) -> ok | {error, term()}` - *optional*; hand the
  live connection behind a `{stream, Reader}` response body to `Owner`. A
  layer that runs the request in a short-lived worker (e.g.
  `livery_client_timeout`) calls this to reparent the connection to the
  process that will read it, before the worker exits. Only adapters whose
  streamed reader is tied to its owning process need it.
""".

-type stream_ref() :: term().
-type stream_opts() :: #{stream_to := pid(), flow := auto | manual}.
-export_type([stream_ref/0, stream_opts/0]).

-callback request(livery_client:request(), map()) ->
    {ok, livery_client:response()} | {error, term()}.

-callback read(term(), timeout()) ->
    {ok, binary(), term()} | {done, term()} | {error, term()}.

-callback stream(livery_client:request(), map(), stream_opts()) ->
    {ok, stream_ref()} | {error, term()}.

-callback stream_next(stream_ref()) -> ok | {error, term()}.

-callback stop_stream(stream_ref()) -> ok.

-callback adopt(term(), pid()) -> ok | {error, term()}.

-optional_callbacks([read/2, stream/3, stream_next/1, stop_stream/1, adopt/2]).
