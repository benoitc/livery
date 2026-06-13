# How to generate OpenAPI docs and validate requests

Livery can turn your route metadata into an OpenAPI 3.1 spec, serve a
browsable docs page from it, and reject malformed request bodies. You
need this when you want a machine-readable contract for your routes and
automatic validation against it.

## Generate the spec

`livery_openapi:build/1` turns route metadata into an OpenAPI 3.1
document. Livery path templates (`:param`, `*wildcard`) become `{param}`
and gain synthesised path parameters:

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

Both UIs are self-contained HTML pages that load the spec from a URL; the
JS bundles come from a CDN, so no static files are needed. Pick one:

```erlang
%% Redoc
{<<"GET">>, <<"/docs">>, livery_openapi:redoc_handler()}

%% Swagger UI
{<<"GET">>, <<"/docs">>, livery_openapi:swagger_ui_handler()}
```

Pass a custom spec URL to either: `redoc_handler(<<"/v2/openapi.json">>)`.

## Validate request bodies

`livery_openapi_validate` rejects bodies that do not match a schema with
`422`, and stores the decoded body under `meta(body, _)` on success:

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

Supported keywords cover `type` (single or a list), `enum`, `const`, the
numeric bounds (`minimum`/`maximum`/`exclusive*`/`multipleOf`), string
`minLength`/`maxLength`/`pattern`, object
`required`/`properties`/`additionalProperties`/`min`/`maxProperties`,
array `items`/`min`/`maxItems`/`uniqueItems`, and the
`allOf`/`anyOf`/`oneOf` combinators. A `422` body lists each failure as
`{path, error}`.

## See also

- Reference: `livery_openapi`, `livery_openapi_validate`
- Concept: [Routing](../concepts/routing.md)
