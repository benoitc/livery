# Request and response model

A handler in Livery is a plain function: it takes one request value and
returns one response value. No mutable request object, no response handle
you write into, no `init/2` and reply tuple. One value in, one value out.
That is the whole model, and it is why handlers are trivial to test (you
build a request, you check the response) and safe to pass between
processes.

```erlang
greet(Req) ->
    Name = livery_req:binding(<<"name">>, Req),
    livery_resp:text(200, [<<"hello, ">>, Name]).
```

## Requests are values

A request is an immutable `#livery_req{}` record. You read it through
`livery_req` accessors and, in middleware, derive a new value with the
setters and pass it on with `Next(Req1)`. The fields:

| Field | Type | Source |
|---|---|---|
| `protocol` | `h1 \| h2 \| h3` | adapter |
| `method` | `binary()` | adapter |
| `scheme` | `binary()` | adapter (`<<"http">>`/`<<"https">>`) |
| `authority` | `binary()` | adapter (host:port) |
| `path` | `binary()` | adapter |
| `raw_query` | `binary()` | adapter |
| `bindings` | `#{binary() => binary()}` | router |
| `headers` | `[{binary(), binary()}]` | adapter (lowercased names) |
| `peer` | `{ip, port} \| undefined` | adapter |
| `tls` | `map() \| undefined` | adapter |
| `body` | `empty \| {buffered, _} \| {stream, _}` | adapter |
| `req_id` | `binary()` | middleware (e.g. `livery_request_id`) |
| `meta` | `map()` | middleware |

Reading the common things looks like this:

```erlang
Method = livery_req:method(Req),                       %% <<"POST">>
Id     = livery_req:binding(<<"id">>, Req),            %% from /things/:id
Accept = livery_req:header(<<"accept">>, Req),         %% undefined if absent
Page   = livery_ext:query(<<"page">>, Req).            %% query string param
```

`meta` is your extension point. Use `livery_req:set_meta/3` and
`livery_req:meta/2,3` to carry values without growing the record (see
"Threading values" below).

## Reading the body

The body is one of three shapes, and the adapter chooses which:

- `empty` - there is no body.
- `{buffered, IoData}` - the adapter already has it in memory.
- `{stream, Reader}` - pull it with `livery_body`.

The socket adapters deliver `{stream, Reader}`, so read it to the end
before decoding. Accepting `{buffered, _}` too means the same handler
also runs under the in-memory test adapter:

```erlang
read_json(Req) ->
    Bin =
        case livery_req:body(Req) of
            {stream, Reader}   -> {ok, B, _} = livery_body:read_all(Reader), B;
            {buffered, IoData} -> iolist_to_binary(IoData);
            empty              -> <<>>
        end,
    try {ok, json:decode(Bin)} catch _:_ -> {error, invalid_json} end.
```

For huge bodies you can stream rather than buffer; see
[Streaming and backpressure](streaming-and-backpressure.md).

## Responses are values

A response is an immutable `#livery_resp{}`. You build one with a
`livery_resp` constructor and, if needed, adjust it with the setters. The
constructor encodes the body variant, and `livery:emit/3` walks that
variant into adapter calls:

| Body variant | Built by | Emission |
|---|---|---|
| `empty` | `empty/1` | one `send_headers`, stream ended |
| `{full, IoData}` | `json/2`, `text/2`, `html/2` | headers + body (coalesced where possible) |
| `{chunked, Producer}` | `stream/3` | headers + repeated `send_data` |
| `{sse, Producer}` | `sse/2,3` | as chunked, with SSE framing |
| `{file, Path, Range}` | `file/2,3` | `sendfile` where supported |
| `{upgrade, ws \| wt, _}` | `upgrade/2` | handed to `livery_ws`/`livery_wt` |

**Which constructor, when:**

| Situation | Use |
|---|---|
| JSON API reply | `livery_resp:json/2` |
| plain text / health check | `livery_resp:text/2` |
| an HTML page | `livery_resp:html/2` |
| created a resource, point at it | `json/2` + `livery_resp:with_header/3` (`location`) |
| nothing to return (204, etc.) | `livery_resp:empty/1` |
| send the caller elsewhere | `livery_resp:redirect/2` |
| a file on disk | `livery_resp:file/2` |
| a live or unbounded body | `stream/3`, `sse/2`, `ndjson/2` |

A created-resource reply, lifting the location into a variable (a binary
with an embedded comma would otherwise read oddly):

```erlang
create(Req) ->
    Note = save(Req),
    Id = maps:get(<<"id">>, Note),
    Location = <<"/notes/", Id/binary>>,
    Resp = livery_resp:json(201, json:encode(Note)),
    livery_resp:with_header(<<"location">>, Location, Resp).
```

Headers are lowercased on construction and on `with_header/3` /
`append_header/3`, so later lookups are case-direct.

## Threading values from middleware to handler

When a middleware computes something the handler needs (the
authenticated user, a parsed body, a trace id), it stores it in `meta`
and the handler reads it back. Nothing mutates; each stage passes a new
request forward.

```erlang
%% in a middleware's call/3
authenticate(Req, Next) ->
    User = lookup_user(Req),
    Next(livery_req:set_meta(user, User, Req)).

%% in the handler
profile(Req) ->
    User = livery_req:meta(user, Req),
    livery_resp:json(200, json:encode(User)).
```

## Config vs meta

These two look similar but do opposite jobs, so keep them straight:

- **`config`** is service-wide and set once at startup: a DB pool, a
  cache, settings. The same value for every request, read-only, via
  `livery_req:config/1`. See
  [Share config across handlers](../guides/share-config.md).
- **`meta`** is per-request scratch a middleware writes for this one
  request: the authenticated user, a trace id, a parsed body, via
  `livery_req:set_meta/3` and `meta/2`.

If you find yourself putting a database pool in `meta`, you want
`config`; if you put the current user in `config`, you want `meta`.

## Extractors

`livery_ext` is a thin typed layer over the accessors. It returns a value
or `{error, Reason}`, so you can pattern-match the good case:

| Extractor | Returns |
|---|---|
| `livery_ext:json/1` | `{ok, Term} \| {error, _}` |
| `livery_ext:form/1` | `{ok, [{Key, Value}]} \| {error, _}` |
| `livery_ext:query/2` | `binary() \| undefined` |
| `livery_ext:header/2` | `binary() \| undefined` |
| `livery_ext:bearer_token/1` | `binary() \| undefined` |

`livery_ext:json/1` works on a buffered body; for a streamed body read it
with `livery_body` first, as shown above.

## See also

- Tutorial: [Your first service](../tutorials/your-first-service.md)
- Tutorial: [Build a complete service](../tutorials/build-a-complete-service.md)
- Guide: [Parse a JSON body](../guides/parse-json-bodies.md)
- Reference: `livery_req`, `livery_resp`, `livery_ext`
