# Streaming Responses

Livery supports streaming responses for large content, real-time data, and Server-Sent Events (SSE).

## Basic Streaming

Use the `{stream, ...}` return tuple to send chunked responses:

```erlang
handle(_Req, State) ->
    StreamFun = fun(Send) ->
        Send(<<"First chunk\n">>),
        Send(<<"Second chunk\n">>),
        Send(<<"Third chunk\n">>),
        Send(done)
    end,
    {stream, 200,
     [{<<"content-type">>, <<"text/plain">>}],
     StreamFun,
     State}.
```

The `Send` function accepts:
- `Binary` - Send a chunk of data
- `done` - End the stream
- `{done, Trailers}` - End with HTTP trailers

## Streaming Large Files

```erlang
handle(Req, State) ->
    FilePath = get_file_path(Req),
    case file:open(FilePath, [read, binary]) of
        {ok, File} ->
            StreamFun = fun(Send) ->
                stream_file(File, Send),
                file:close(File),
                Send(done)
            end,
            ContentType = guess_content_type(FilePath),
            {stream, 200,
             [{<<"content-type">>, ContentType}],
             StreamFun,
             State};
        {error, enoent} ->
            livery_helpers:reply_not_found(State)
    end.

stream_file(File, Send) ->
    case file:read(File, 64 * 1024) of  % 64KB chunks
        {ok, Data} ->
            Send(Data),
            stream_file(File, Send);
        eof ->
            ok
    end.
```

## Server-Sent Events (SSE)

SSE provides a simple way to push events from server to client:

```erlang
-module(sse_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(_Req, State) ->
    StreamFun = fun(Send) ->
        %% Send 10 events, one per second
        sse_loop(Send, 0)
    end,
    {stream, 200,
     [{<<"content-type">>, <<"text/event-stream">>},
      {<<"cache-control">>, <<"no-cache">>},
      {<<"connection">>, <<"keep-alive">>}],
     StreamFun,
     State}.

sse_loop(Send, Count) when Count < 10 ->
    %% SSE format: "data: <content>\n\n"
    Event = io_lib:format("data: ~s~n~n", [json:encode(#{count => Count})]),
    Send(iolist_to_binary(Event)),
    timer:sleep(1000),
    sse_loop(Send, Count + 1);
sse_loop(Send, _) ->
    Send(done).
```

### SSE with Event Types

```erlang
send_sse_event(Send, Type, Data) ->
    Event = io_lib:format("event: ~s~ndata: ~s~n~n", [Type, json:encode(Data)]),
    Send(iolist_to_binary(Event)).

sse_handler(Send) ->
    send_sse_event(Send, <<"message">>, #{text => <<"Hello">>}),
    send_sse_event(Send, <<"update">>, #{value => 42}),
    send_sse_event(Send, <<"error">>, #{code => 500}),
    Send(done).
```

### SSE with IDs and Retry

```erlang
send_sse_full(Send, Id, Type, Data, Retry) ->
    Parts = [
        case Id of undefined -> <<>>; _ -> io_lib:format("id: ~s~n", [Id]) end,
        case Type of undefined -> <<>>; _ -> io_lib:format("event: ~s~n", [Type]) end,
        case Retry of undefined -> <<>>; _ -> io_lib:format("retry: ~p~n", [Retry]) end,
        io_lib:format("data: ~s~n~n", [json:encode(Data)])
    ],
    Send(iolist_to_binary(Parts)).
```

## Real-Time Updates

Connect SSE to your application events:

```erlang
-module(realtime_handler).
-behaviour(livery_handler).
-export([init/2, handle/2]).

init(Req, Opts) ->
    {ok, Req, Opts}.

handle(_Req, State) ->
    Self = self(),
    %% Subscribe to updates
    pubsub:subscribe(updates, Self),

    StreamFun = fun(Send) ->
        realtime_loop(Send)
    end,
    {stream, 200,
     [{<<"content-type">>, <<"text/event-stream">>},
      {<<"cache-control">>, <<"no-cache">>}],
     StreamFun,
     State}.

realtime_loop(Send) ->
    receive
        {update, Data} ->
            Event = io_lib:format("data: ~s~n~n", [json:encode(Data)]),
            Send(iolist_to_binary(Event)),
            realtime_loop(Send);
        stop ->
            Send(done)
    after 30000 ->
        %% Send keepalive comment
        Send(<<": keepalive\n\n">>),
        realtime_loop(Send)
    end.
```

## Streaming with Trailers

HTTP trailers allow sending headers after the body:

```erlang
handle(_Req, State) ->
    StreamFun = fun(Send) ->
        %% Initialize hash
        Hash = crypto:hash_init(sha256),

        %% Stream content and update hash
        Hash1 = send_chunks(Send, Hash),

        %% Calculate final hash
        Digest = crypto:hash_final(Hash1),
        DigestHex = binary:encode_hex(Digest),

        %% Send trailers with checksum
        Send({done, [{<<"x-content-sha256">>, DigestHex}]})
    end,
    {stream, 200,
     [{<<"content-type">>, <<"application/octet-stream">>},
      {<<"trailer">>, <<"x-content-sha256">>}],
     StreamFun,
     State}.

send_chunks(Send, Hash) ->
    %% Stream data chunks
    Chunks = [<<"chunk1">>, <<"chunk2">>, <<"chunk3">>],
    lists:foldl(fun(Chunk, H) ->
        Send(Chunk),
        crypto:hash_update(H, Chunk)
    end, Hash, Chunks).
```

## Client-Side SSE

### JavaScript

```javascript
const evtSource = new EventSource('/events');

evtSource.onmessage = (event) => {
    console.log('Message:', JSON.parse(event.data));
};

evtSource.addEventListener('update', (event) => {
    console.log('Update:', JSON.parse(event.data));
});

evtSource.onerror = (err) => {
    console.error('SSE error:', err);
};

// Close connection
evtSource.close();
```

### curl

```bash
# Stream SSE events
curl -N http://localhost:8080/events

# With headers
curl -N -H "Accept: text/event-stream" http://localhost:8080/events
```

## Chunked Response Building

The `livery_resp` module provides low-level chunked encoding:

```erlang
%% Build chunked response start
Start = livery_resp:build_chunked_start(200, Headers, {1, 1}),

%% Encode a chunk
Chunk = livery_resp:encode_chunk(<<"Hello">>),
% Result: "5\r\nHello\r\n"

%% Encode last chunk (no trailers)
Last = livery_resp:encode_last_chunk(),
% Result: "0\r\n\r\n"

%% Encode last chunk with trailers
Last = livery_resp:encode_last_chunk([{<<"x-checksum">>, <<"abc">>}]),
% Result: "0\r\nx-checksum: abc\r\n\r\n"
```

## Performance Considerations

1. **Buffer Size**: Send reasonably sized chunks (e.g., 64KB for files)
2. **Backpressure**: The Send function blocks until data is written
3. **Timeouts**: Keep streams active with periodic data or comments
4. **Resource Cleanup**: Ensure resources are cleaned up when streaming ends
