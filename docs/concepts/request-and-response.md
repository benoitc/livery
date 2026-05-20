# Request and response model

## Requests are values

A request is an immutable `#livery_req{}` record. Middleware reads
it via `livery_req` accessors, derives a new value with setters,
and threads it forward by calling `Next(Req1)`. There is no
mutable handle, no `Req0/Req1` ceremony, no callback module.

Fields:

| Field | Type | Source |
|---|---|---|
| `protocol` | `h1 \| h2 \| h3` | adapter |
| `method` | `binary()` | adapter |
| `scheme` | `binary()` | adapter (`<<"http">>`/`<<"https">>`) |
| `authority` | `binary()` | adapter (host:port) |
| `path` | `binary()` | adapter, post-router |
| `raw_query` | `binary()` | adapter |
| `bindings` | `#{binary() => binary()}` | router |
| `headers` | `[{binary(), binary()}]` | adapter (lowercased names) |
| `peer` | `{ip, port} \| undefined` | adapter |
| `tls` | `map() \| undefined` | adapter |
| `body` | `empty \| {buffered, _} \| {stream, _}` | adapter |
| `adapter` | `module()` | adapter |
| `stream` | adapter-specific | adapter |
| `engine_pid` | `pid() \| undefined` | adapter |
| `req_id` | `binary()` | middleware (e.g. `livery_request_id`) |
| `started_at` | `integer() \| undefined` | `livery_req_proc` |
| `meta` | `map()` | middleware |

`meta` is the user-controlled extension point. Use
`livery_req:set_meta/3` and `livery_req:meta/2,3` to thread values
from middleware to handler without expanding the record.

## Responses are values

A response is an immutable `#livery_resp{}`. The handler returns
one; `livery:emit/3` walks it into adapter callbacks.

| Body variant | Emission |
|---|---|
| `empty` | one `send_headers` with `end_stream` |
| `{full, IoData}` | `send_headers` + `send_data` (+ `send_trailers`) |
| `{chunked, Producer}` | `send_headers` + repeated `send_data` from `Emit` |
| `{sse, Producer}` | as chunked, with SSE framing applied to each event |
| `{file, Path, Range}` | `sendfile` on adapters that support it |
| `{upgrade, ws \| wt, _}` | handed off to `livery_ws` / `livery_wt` |

Headers are lowercased on construction (or on `with_header/3`,
`append_header/3`). Lookup is case-direct after that.

## Body shapes

Inbound body is one of:

- `empty` — no body.
- `{buffered, IoData}` — the adapter has the whole body in memory.
- `{stream, Reader}` — call `livery_body:read/2` to drain.

The H1/H2/H3 adapters choose buffered or streaming based on a
per-route config (Phase 2+). The test adapter always sets whatever
the test spec passed in.

## Extractors

`livery_ext` is a thin layer over the request accessors that
returns typed values or `{error, Reason}`:

| Extractor | Returns |
|---|---|
| `livery_ext:json/1` | `{ok, Term} \| {error, _}` |
| `livery_ext:form/1` | `{ok, [{Key, Value}]} \| {error, _}` |
| `livery_ext:path_param/2` | `binary() \| undefined` |
| `livery_ext:query/2` | `binary() \| undefined` |
| `livery_ext:header/2` | `binary() \| undefined` |
| `livery_ext:bearer_token/1` | `binary() \| undefined` |

## See also

- Reference: `livery_req`
- Reference: `livery_resp`
- Reference: `livery_ext`
