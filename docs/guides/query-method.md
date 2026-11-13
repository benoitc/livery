# How to handle QUERY requests

QUERY (RFC 10008) is an HTTP method that behaves like GET with a body:
it is safe and idempotent, so it never changes state and can be sent
again without harm, but it carries its search criteria in the request
body instead of the URL. You need it when a search is too structured
or too large for a query string, and POST would lose the promise that
the request changes nothing.

## Route it

You register a QUERY route like a route for any other method:

```erlang
Router = livery_router:compile([
    {<<"QUERY">>, <<"/documents/search">>, {docs, search}}
]).
```

If a path accepts only QUERY, requests with another method get a `405`,
and its `Allow` header lists `QUERY` for you.

## Handle it

The body arrives like a POST body, and you read it the same way:

```erlang
search(Req) ->
    {stream, Reader} = livery_req:body(Req),
    {ok, Bin, _} = livery_body:read_all(Reader),
    #{<<"q">> := Q} = json:decode(Bin),
    livery_resp:json(200, json:encode(documents:search(Q))).
```

Headers, query string parameters, and path bindings all work as
usual.

## Call it

The client has a helper that works like `post/3`:

```erlang
Client = livery_client:new(#{base_url => <<"https://api.example.com">>}),
{ok, Resp} = livery_client:query(
    Client,
    <<"/documents/search">>,
    json:encode(#{q => <<"boots">>, limit => 20})
).
```

Because QUERY is idempotent, the `livery_client:retry/1` layer sends a
failed QUERY again, as it does a GET, as long as the body is not a
stream.

## When to prefer QUERY

- Over GET: the criteria are a structured document (JSON filters,
  sub-queries) that would be hard to read or too long in a URL.
- Over POST: the request has no side effects. Using QUERY says so,
  which lets clients retry safely and lets caches store responses,
  keyed on the request content.

Two notes. QUERY routes appear in generated OpenAPI documents as a
`query` operation (OpenAPI 3.2). And `livery_etag` handles conditional
requests on GET and HEAD only, since RFC 9110 defines revalidation
with a 304 for those two methods.

## See also

- Guide: [Parse a JSON body](parse-json-bodies.md)
- Guide: [Make outbound HTTP requests](make-http-requests.md)
- Reference: `livery_router`, `livery_client`
