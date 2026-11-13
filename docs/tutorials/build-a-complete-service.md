# Tutorial: Build a complete service

In this tutorial you start a real service that listens on a socket
and walk the whole path: routing, middleware, reading requests and
writing responses, streaming, WebSockets, serving three protocols at
once, shutting down gracefully, and writing your own adapter. It is
for you once the smaller tutorials feel familiar and you want to see
the pieces fit together. Take your time; it is a longer read, maybe
twenty-five minutes.

Every step has a companion in `examples/livery_example_complete.erl`, so
you can run the finished thing while you read, and in
`examples/livery_example_adapter.erl` for the adapter at the end.

## 1. The app you will build

A tiny notes service. You keep notes in an ETS table and expose them
over HTTP: list them, create one, fetch one, delete one. Then you add a
live events feed and a WebSocket echo on top. It uses every part of
Livery you will need in a real service.

Run it first, so you know where you are going:

```
rebar3 as examples shell
```

```erlang
{ok, Pid} = livery_example_complete:start(8080).
```

In another terminal:

```
curl http://127.0.0.1:8080/notes
curl -XPOST --data '{"text":"buy bread"}' http://127.0.0.1:8080/notes
curl http://127.0.0.1:8080/notes/1
curl -XDELETE http://127.0.0.1:8080/notes/1
```

When you are done, `livery_example_complete:stop(Pid)` puts everything
away. Now build it from scratch.

## 2. Start a service

A service is the front door. `livery:start_service/1` takes one map,
starts the listeners, connects your router, and shares one middleware
stack across all of them.

```erlang
start(Port) ->
    ensure_table(),
    livery:start_service(#{
        http => #{port => Port},
        middleware => base_stack(),
        router => router()
    }).
```

That is the whole startup. The `http` key asks for an HTTP/1.1 listener
on `Port`; `router` and `middleware` you define in the next sections. You
get back `{ok, Pid}`, and `livery:stop_service(Pid)` later stops it.

If you only ever want one protocol, `livery:start_listener/2` starts a
single adapter directly, for example
`livery:start_listener(livery_h1, Opts)`. The service is the easier
choice when you want several protocols sharing one set of handlers, which
is where you are going in section 8.

## 3. Routing

A router maps a method and a path to a handler. You compile a list of
routes once, at startup:

```erlang
router() ->
    livery_router:compile([
        {<<"GET">>, <<"/notes">>, {?MODULE, list_notes}, #{middleware => [list_marker()]}},
        {<<"POST">>, <<"/notes">>, {?MODULE, create_note}},
        {<<"GET">>, <<"/notes/:id">>, {?MODULE, show_note}},
        {<<"DELETE">>, <<"/notes/:id">>, {?MODULE, delete_note}},
        {<<"GET">>, <<"/events">>, {?MODULE, events}},
        {<<"GET">>, <<"/ws">>, {?MODULE, ws}}
    ]).
```

Three kinds of segment exist: a plain word like `notes`, a parameter like
`:id`, and a trailing wildcard like `*rest`. A parameter captures whatever
sits in that slot, and you read it back in the handler:

```erlang
show_note(Req) ->
    Id = livery_req:binding(<<"id">>, Req),
    ...
```

A handler is `{Module, Function}` or a plain `fun((Req) -> Resp)`. The
fourth element of a route, when present, is its `Meta`; you use it here to
attach a per-route middleware, which section 5 comes back to. For the full
matching rules, see [Routing](../concepts/routing.md).

## 4. Request and response

Handlers in Livery are plain: one request value in, one response value
out, no socket in sight. You read what you need from the request, and you
build a response with the `livery_resp` helpers.

Reading the body deserves a word. The socket adapters hand you the body as
a stream, so you read it to the end before you decode it:

```erlang
decode_body(Req) ->
    Bin =
        case livery_req:body(Req) of
            {stream, Reader} ->
                {ok, Data, _} = livery_body:read_all(Reader),
                Data;
            {buffered, IoData} ->
                iolist_to_binary(IoData);
            empty ->
                <<>>
        end,
    try {ok, json:decode(Bin)} catch
        _:_ -> {error, invalid_json}
    end.
```

You accept `{buffered, _}` too, so the same handler runs under the test
adapter in section 11. With that in hand, creating a note is small:

```erlang
create_note(Req) ->
    case decode_body(Req) of
        {ok, #{<<"text">> := Text}} when is_binary(Text) ->
            Note = put_note(Text),
            Id = maps:get(<<"id">>, Note),
            Location = <<"/notes/", Id/binary>>,
            Resp = livery_resp:json(201, json:encode(Note)),
            livery_resp:with_header(<<"location">>, Location, Resp);
        {ok, _} ->
            livery_resp:json(422, <<"{\"error\":\"text is required\"}">>);
        {error, _} ->
            livery_resp:json(400, <<"{\"error\":\"invalid json\"}">>)
    end.
```

You have met most of the response builders already: `livery_resp:json/2`,
`text/2`, and `empty/1` for a bodiless answer like our `204` on delete.
`with_header/3` adds or replaces a header on any response. There are more
(`redirect/2`, `html/2`, `file/2`); see
[Request and response](../concepts/request-and-response.md). To read query
string parameters, use `livery_ext:query/2`, covered in
[Read query strings](../guides/read-query-strings.md).

## 5. Middleware

Middleware is where you put the work every request shares: logging,
request IDs, limits, timing. A Livery middleware receives the request
value and a `Next` function that runs the rest of the stack, and returns
a response, as in Tower and Axum. Nothing is changed in place: this is
not the older style where each step edits shared request and response
objects and then calls `next`. The shape is `call(Req, Next, State)`, or
a `fun((Req, Next))`. You may change the request before calling `Next`,
change the response after, answer on your own by never calling `Next`,
or all three.

Here is a timing middleware, written as a fun:

```erlang
timing() ->
    fun(Req, Next) ->
        Start = erlang:monotonic_time(millisecond),
        Resp = Next(Req),
        Elapsed = erlang:monotonic_time(millisecond) - Start,
        livery_resp:with_header(
            <<"x-response-time-ms">>,
            integer_to_binary(Elapsed),
            Resp
        )
    end.
```

You stack it after the built-ins, and the whole stack runs for every
request, in order:

```erlang
base_stack() ->
    [
        {livery_request_id, undefined},
        {livery_access_log, #{}},
        {livery_body_limit, #{max => 1_048_576}},
        timing()
    ].
```

Sometimes a rule belongs to one route only. That is what the route `Meta`
was for in section 3: the `middleware` key holds a stack that runs only
for that route, nested inside the service-wide one.

```erlang
list_marker() ->
    livery_middleware:after_response(
        fun(Resp) -> livery_resp:with_header(<<"x-list">>, <<"notes">>, Resp) end
    ).
```

`livery_middleware:after_response/1` is a shortcut for the common case
where you only change the response. There is `before/1` for the request
side, and `wrap/1` to catch errors from the rest of the stack and turn
them into a response. More in
[The middleware pipeline](../concepts/middleware-pipeline.md).

## 6. Streaming with Server-Sent Events

Not every response is ready all at once. For a live feed you want to
send events as they happen. `livery_resp:sse/2` gives your function an
`Emit` callback; you call it as often as you like, and Livery formats
each event and sends it.

```erlang
events(_Req) ->
    Count = length(all_notes()),
    livery_resp:sse(200, fun(Emit) ->
        _ = [
            Emit(#{event => <<"notes">>, data => integer_to_binary(Count)})
         || _ <- lists:seq(1, 3)
        ],
        ok
    end).
```

`curl -N http://127.0.0.1:8080/events` shows the events arriving. The same
idea works for chunked bodies (`livery_resp:stream/3`) and NDJSON
(`livery_resp:ndjson/2`). See
[Streaming and backpressure](../concepts/streaming-and-backpressure.md).

## 7. WebSocket

A WebSocket route hands the stream over to a session handler. The route
handler is a one-liner:

```erlang
ws(Req) ->
    livery_ws:upgrade(Req, ?MODULE, #{}).
```

The handler module implements the `ws_handler` behaviour. Ours is a plain
echo: whatever comes in goes back out.

```erlang
init(_Req, _Opts) -> {ok, undefined}.

handle_in({text, Bin}, State)   -> {reply, [{text, Bin}], State};
handle_in({binary, Bin}, State) -> {reply, [{binary, Bin}], State};
handle_in({ping, Bin}, State)   -> {reply, [{pong, Bin}], State};
handle_in({close, Code, _}, State) -> {stop, {closed, Code}, State};
handle_in(_Frame, State)        -> {ok, State}.

handle_info(_Msg, State) -> {ok, State}.
terminate(_Reason, _State) -> ok.
```

The nice part: the upgrade uses the listener you already have. On
HTTP/1.1 it is the usual Upgrade handshake; on HTTP/2 and HTTP/3 it is
extended CONNECT. The same handler works on all three, with nothing
extra to set up.

## 8. Serve three protocols at once

This is what the service is for. Add an `https` key and an
`http3` key to the same map, point all three at the same router, and you
are serving HTTP/1.1, HTTP/2 over TLS, and HTTP/3 over QUIC from one set of
handlers.

```erlang
start_tls(Port) ->
    ensure_table(),
    {ok, Cert, Key} = load_certs(),
    livery:start_service(#{
        http  => #{port => Port},
        https => #{port => Port, cert => Cert, key => Key},
        http3 => #{port => Port, cert => Cert, key => Key},
        middleware => base_stack(),
        router => router()
    }).
```

The example borrows the self-signed certs under `test/certs`, which are
for local testing only, never production. Add `alt_svc => advertise` to
the map and the service advertises HTTP/3 with an `Alt-Svc` header on
the H1 and H2 responses, so clients that support HTTP/3 can switch to
it. Without it, no `Alt-Svc` header is sent. To bind to a specific address or use
IPv6, see
[Bind to an address or IPv6](../guides/bind-listen-address.md), and for the
bigger picture, [Adapters](../concepts/adapters.md).

## 9. Shut down gracefully

Cutting a request off halfway is rude to the client. `livery:drain/2`
stops accepting new connections, waits for the requests already running to finish, then stops
the service.

```erlang
ok = livery:drain(Pid, #{timeout => 30000}).
```

If you want to watch it happen, `livery_drain:in_flight/0` tells you how
many requests are still running. More in
[Shut down gracefully](../guides/graceful-shutdown.md).

## 10. Write your own adapter

So far you have used the adapters that ship with Livery. What if you have a
transport they do not cover? You write an adapter. It is less work than it
sounds, because an adapter holds almost no logic: the protocol's framing
and TLS live in the wire library, routing and middleware live in Livery
above it. The adapter translates between the two.

An adapter implements the `livery_adapter` behaviour, eight callbacks:

```erlang
start(Name, ListenSpec, Opts) -> {ok, Listener}.
stop(Listener)               -> ok.
send_headers(Stream, Status, Headers, SendOpts) -> SendResult.
send_data(Stream, IoData, SendOpts)             -> SendResult.
send_trailers(Stream, Trailers)                 -> SendResult.
reset(Stream, Reason)                           -> ok.
peer_info(Stream)                               -> map().
capabilities(Listener)                          -> map().
```

The lifecycle is the same for every adapter. On a new request you spawn a
worker with `livery_req_sup:start_request/1`, feed the body into it as
`{livery_body, Ref, _}` messages, and the worker runs your middleware and
handler and drives the response back out through `livery:emit/3`, which
calls the `send_*` callbacks above.

`examples/livery_example_adapter.erl` is a short, runnable adapter that
does this, with one shortcut: instead of a socket it stores the
response in an ETS table, so you can see how the pieces connect without
a network. The main part is the function that drives a request:

```erlang
request(Listener, Stack, Handler, Spec) ->
    Stream = new_stream(Listener),
    BodyRef = make_ref(),
    Reader = livery_body:new(BodyRef),
    Req0 = livery_req:new(Fields),
    Req = Req0#livery_req{adapter = ?MODULE, stream = Stream, body = {stream, Reader}},
    {ok, Worker} = livery_req_sup:start_request(#{
        adapter => ?MODULE, stream => Stream, req => Req,
        stack => Stack, handler => Handler
    }),
    MRef = erlang:monitor(process, Worker),
    Worker ! {livery_body, BodyRef, eof},
    receive {'DOWN', MRef, process, Worker, _} -> ok after 5000 -> error(worker_timeout) end,
    capture(Stream).
```

To turn this into a real transport, keep the callbacks, replace the ETS
sink with socket writes, and translate your wire's incoming body events
into `{livery_body, Ref, _}` messages (the `{h1_stream, _}` loop in
`livery_h1` is the template). When it works, add a group to
`test/livery_parity_SUITE.erl` so your adapter is held to the same
behaviour, seen from outside, as the others. `livery_test_adapter` is the
smallest complete adapter to compare against, and
[Adapters](../concepts/adapters.md) explains in full what an adapter must
do.

## 11. Test it without a socket

Because a handler takes a request value and returns a response value, you
can test it with no service running at all. `livery_test_adapter:run/3` builds a request,
runs the stack and handler, and captures the response:

```erlang
create_rejects_bad_json_test() ->
    Cap = livery_test_adapter:run(
        [], fun livery_example_complete:create_note/1,
        #{method => <<"POST">>, body => {buffered, <<"not json">>}}),
    ?assertEqual(400, livery_test_adapter:status(Cap)).
```

(The happy path writes to the notes table that `start/1` creates, so a
test that creates a note would set the table up first or drive the live
service. The rejection path answers before touching the store, which
makes it the simplest thing to check in isolation.)

That is also how the example adapter is tested end to end, in
`test/livery_example_adapter_tests.erl`. For the four levels of testing,
see [Test your handlers](testing-handlers.md).

## Next steps

You have now seen the whole core. From here, the how-to guides go further
into the more specialised parts:

- [Verify opaque tokens (introspection)](../guides/token-introspection.md)
  and [Extract a bearer token](../guides/bearer-tokens.md) for auth.
- [OpenAPI docs and validation](../guides/openapi-and-validation.md).
- [Serve MCP tools](../guides/serve-mcp-tools.md).
- [Serve WebTransport](../guides/serve-webtransport.md).
- [Export Prometheus metrics](../guides/export-metrics.md).
