# How to generate OpenAPI docs and validate requests

## Problem

Your routes already exist in code, and now someone wants the spec,
the pretty docs page, and a guarantee that junk request bodies never
reach your handlers. You would rather not write all of that by hand,
and you do not have to. Here we generate the OpenAPI document from
your routes, serve a docs UI, and let a schema reject bad bodies for
you.

## Generate the spec

`livery_openapi:build/1` reads your route metadata and hands back an
OpenAPI 3.1 document. Your Livery path templates (`:param`,
`*wildcard`) become `{param}`, and the matching path parameters are
filled in for you:

```erlang
Doc = livery_openapi:build(#{
    info   => #{title => <<"My API">>, version => <<"1.0.0">>},
    routes => [
        {<<"GET">>, <<"/users/:id">>, {users, show},
         #{summary   => <<"Fetch a user">>,
           responses => #{200 => #{description => <<"the user">>}}}}
    ]
}).
```

Serve it as JSON with `livery_openapi:handler/1`, mounted at
`/openapi.json`:

```erlang
{<<"GET">>, <<"/openapi.json">>, livery_openapi:handler(Doc)}
```

## Serve a docs UI

Both UIs are single self-contained HTML pages that fetch the spec
from a URL. The JS bundles come from a CDN, so you ship no static
files at all. Pick the one you like:

```erlang
%% Redoc
{<<"GET">>, <<"/docs">>, livery_openapi:redoc_handler()}

%% Swagger UI
{<<"GET">>, <<"/docs">>, livery_openapi:swagger_ui_handler()}
```

Pass a custom spec URL to either: `redoc_handler(<<"/v2/openapi.json">>)`.

## Validate request bodies

Drop `livery_openapi_validate` into the stack and bad bodies stop at
the door: anything that does not match the schema gets a `422`, and a
valid body is decoded and tucked away under `meta(body, _)` for your
handler:

```erlang
Schema = #{
    type     => <<"object">>,
    required => [<<"email">>],
    properties => #{
        <<"email">> => #{type => <<"string">>, pattern => <<"@">>},
        <<"age">>   => #{type => <<"integer">>, minimum => 0}
    },
    additionalProperties => false
}.

Stack = [{livery_openapi_validate, #{body_schema => Schema}}],
```

The keywords you can lean on cover `type` (single or a list), `enum`,
`const`, the numeric bounds (`minimum`/`maximum`/`exclusive*`/
`multipleOf`), string `minLength`/`maxLength`/`pattern`, object
`required`/`properties`/`additionalProperties`/`min`/`maxProperties`,
array `items`/`min`/`maxItems`/`uniqueItems`, and the `allOf`/
`anyOf`/`oneOf` combinators. A `422` body lists each failure as
`{path, error}`.

## See also

- Reference: `livery_openapi`, `livery_openapi_validate`
- Concept: [Routing](../concepts/routing.md)
