# How to handle QUERY requests

QUERY (RFC 10008) is an HTTP method that behaves like GET with a body:
it is safe and idempotent, so it never changes state and may be
repeated freely, yet it carries its search criteria in the request
body instead of the URL. You need it when a search is too structured
or too large for a query string, and POST would throw away the safe
semantics.

## Route it

A QUERY route registers exactly like any other method:

```erlang
Router = livery_router:compile([
    {<<"QUERY">>, <<"/documents/search">>, {docs, search}}
]).
```

If a path accepts only QUERY, requests with another method get a `405`
whose `Allow` header lists `QUERY` automatically.

## Handle it

The body arrives exactly like a POST body; read it the same way:

```erlang
search(Req) ->
    {stream, Reader} = livery_req:body(Req),
    {ok, Bin, _} = livery_body:read_all(Reader),
    #{<<"q">> := Q} = json:decode(Bin),
    livery_resp:json(200, json:encode(documents:search(Q))).
```

Headers, query string parameters, and path bindings all work
unchanged.

## Call it

The client has a helper that mirrors `post/3`:

```erlang
Client = livery_client:new(#{base_url => <<"https://api.example.com">>}),
{ok, Resp} = livery_client:query(
    Client,
    <<"/documents/search">>,
    json:encode(#{q => <<"boots">>, limit => 20})
).
```

Because QUERY is idempotent, the `livery_client:retry/1` layer replays
a failed QUERY like a GET, as long as the body is not a stream.

## When to prefer QUERY

- Over GET: the criteria form a structured document (JSON filters,
  sub-queries) that would be unreadable or oversized in a URL.
- Over POST: the request has no side effects. Saying so with QUERY
  lets clients retry safely and lets caches store responses, keyed on
  the request content.

Two notes. QUERY routes appear in generated OpenAPI documents as a
`query` operation (OpenAPI 3.2). And `livery_etag` keeps its
conditional handling on GET and HEAD only, since RFC 9110 defines the
304 revalidation flow for those two methods.

## See also

- Guide: [Parse a JSON body](parse-json-bodies.md)
- Guide: [Make outbound HTTP requests](make-http-requests.md)
- Reference: `livery_router`, `livery_client`
