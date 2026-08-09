# How to send Early Hints

`livery_req:inform/3` sends an interim (1xx) response before your
real one. The main use is `103 Early Hints`: you tell the browser
which assets the page will need while your handler is still building
it, so stylesheets and scripts start downloading during your own
processing time. Use it when a response takes real work (a database
query, an upstream call) and the asset list is known up front.

## Send hints, then respond

Call `inform/3` from your handler, any time before you return the
response. It can be called more than once.

```erlang
page(Req) ->
    _ = livery_req:inform(103, [
        {<<"link">>, <<"</assets/app.css>; rel=preload; as=style">>},
        {<<"link">>, <<"</assets/app.js>; rel=preload; as=script">>}
    ], Req),
    Body = render_page(),   %% the slow part
    livery_resp:html(200, Body).
```

The interim response goes out immediately; the final `200` follows
as usual and is completely independent, so repeat any headers that
matter there (the `103` block is advisory only).

## Ignore the return value

Hints are best-effort. `inform/3` returns `ok` when the interim
response was written, or `{error, Reason}` when it could not be:

- HTTP/1.1 and HTTP/2 send it on the wire. HTTP/1.1 skips HTTP/1.0
  clients (RFC 9110 forbids 1xx there) and returns
  `{error, http_1_0}`.
- HTTP/3 does not support it yet and returns
  `{error, unsupported}`.

Matching `_ = livery_req:inform(...)` and moving on is the normal
pattern; a page that loads without hints is still a page.

## Notes

- `101` is reserved for the upgrade machinery
  (`livery_ws:upgrade/3`) and rejected.
- Adapters report support in `capabilities/1` as
  `informational => boolean()` if you need to branch.
- Middleware only sees the final response; interim responses bypass
  the response pipeline by design (nothing should compress or cache
  a `103`).
