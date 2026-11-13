# How to send Early Hints

`livery_req:inform/3` sends an interim (1xx) response before your
real one. The main use is `103 Early Hints`: you tell the browser
which assets the page will need while your handler is still building
it, so stylesheets and scripts start downloading while your handler
works. Use it when a response takes real work (a database query, an
upstream call) and you know the asset list from the start.

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

The interim response goes out at once. The final `200` follows as
usual and takes nothing from it, so repeat there any headers that
matter (the `103` headers are only hints).

## Ignore the return value

Hints are sent when they can be. `inform/3` returns `ok` when the interim
response was written, or `{error, Reason}` when it could not be:

- HTTP/1.1, HTTP/2 and HTTP/3 send it on the wire.
- HTTP/1.1 skips HTTP/1.0 clients (RFC 9110 forbids 1xx there) and
  returns `{error, http_1_0}`.

Matching `_ = livery_req:inform(...)` and moving on is the normal
pattern; a page that loads without hints is still a page.

## Notes

- `101` is kept for upgrades (`livery_ws:upgrade/3`) and refused
  here.
- Adapters report support in `capabilities/1` as
  `informational => boolean()` if you need to branch.
- Middleware only sees the final response. Interim responses skip
  the middleware on purpose (nothing should compress or cache a
  `103`).
