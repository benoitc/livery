# How to generate OpenAPI docs and validate requests

Livery can build an OpenAPI 3.2 spec from your route metadata, serve a
documentation page from it, and refuse request bodies that do not match
a schema. You need this when you want a description of your routes that
tools can read, and requests checked against it.

## Generate the spec

`livery_openapi:build/1` turns route metadata into an OpenAPI 3.2
document. Livery path templates (`:param`, `*wildcard`) become `{param}`,
and Livery adds the matching path parameters for you:

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

Each UI is a single HTML page that loads the spec from a URL. Its
JavaScript comes from a CDN, so you do not serve any static files. Pick
one:

```erlang
%% Redoc
{<<"GET">>, <<"/docs">>, livery_openapi:redoc_handler()}

%% Swagger UI
{<<"GET">>, <<"/docs">>, livery_openapi:swagger_ui_handler()}
```

To load the spec from another URL, pass it to either handler:
`redoc_handler(<<"/v2/openapi.json">>)`.

## Validate request bodies

`livery_openapi_validate` answers `422` when a body does not match the
schema. When it matches, the decoded body is stored under
`meta(body, _)`:

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

The validator knows `type` (single or a list), `enum`, `const`, the
numeric bounds (`minimum`/`maximum`/`exclusive*`/`multipleOf`), string
`minLength`/`maxLength`/`pattern`, object
`required`/`properties`/`additionalProperties`/`min`/`maxProperties`,
array `items`/`min`/`maxItems`/`uniqueItems`, and
`allOf`/`anyOf`/`oneOf` to combine schemas. A `422` body lists each failure as
`{path, error}`.

## See also

- Reference: `livery_openapi`, `livery_openapi_validate`
- Concept: [Routing](../concepts/routing.md)
