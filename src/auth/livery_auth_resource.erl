-module(livery_auth_resource).
-moduledoc """
OAuth protected resource metadata (RFC 9728).

Publishes the document a client reads to learn how to get a token for
your API: which authorization servers issue them, which scopes exist,
and whether tokens must be bound to a client certificate or a DPoP key.

```erlang
Meta = #{
    resource => <<"https://api.example/orders">>,
    authorization_servers => [<<"https://issuer.example">>],
    scopes_supported => [<<"orders:read">>, <<"orders:write">>],
    binding => dpop
},
Router1 = livery_router:add(
    <<"GET">>, livery_auth_resource:well_known_path(maps:get(resource, Meta)),
    livery_auth_resource:handler(Meta), #{}, Router0
).
```

Pass `resource_metadata => livery_auth_resource:well_known_url(Resource)`
to `livery_auth_bearer` or `livery_auth_introspect` so refused requests
point clients at it (RFC 9728 section 5.1).

`metadata/1` takes `resource` (required) and the optional
`authorization_servers`, `scopes_supported`, `resource_name`,
`resource_documentation`, `resource_policy_uri` and `resource_tos_uri`.
It fills `bearer_methods_supported` with `header`, the only place
Livery reads a token from, and derives the binding fields from the same
`binding`, `dpop` and `algorithms` options the middlewares take, so you
can pass one map to both.

Deviations: Livery cannot check that `resource` is the URL clients
actually use (RFC 9728 section 3.3); set it to your public URL. See
AGENTS.md, Known deviations.
""".

-export([metadata/1, handler/1, well_known_path/1, well_known_url/1]).

-define(FIELDS, [
    authorization_servers,
    scopes_supported,
    resource_name,
    resource_documentation,
    resource_policy_uri,
    resource_tos_uri
]).

-doc "The metadata document for `Opts`, as a JSON-ready map.".
-spec metadata(#{resource := binary(), atom() => term()}) -> #{binary() => term()}.
metadata(#{resource := Resource} = Opts) ->
    Binding = maps:get(binding, Opts, none),
    Base = #{
        <<"resource">> => Resource,
        <<"bearer_methods_supported">> => [<<"header">>],
        <<"tls_client_certificate_bound_access_tokens">> => lists:member(Binding, [mtls, any])
    },
    Fields = maps:from_list([
        {atom_to_binary(K), V}
     || K <- ?FIELDS, V <- [maps:get(K, Opts, undefined)], V =/= undefined
    ]),
    maps:merge(maps:merge(Base, Fields), dpop_fields(Binding, Opts)).

-doc "A handler that serves the document as `application/json`.".
-spec handler(#{resource := binary(), atom() => term()}) -> livery_middleware:handler().
handler(Opts) ->
    Body = iolist_to_binary(json:encode(metadata(Opts))),
    fun(_Req) -> livery_resp:json(200, Body) end.

-doc """
Where the document lives for `Resource`: the well-known segment goes
before the resource's path (RFC 9728 section 3.1), so
`https://api.example/orders` is served at
`/.well-known/oauth-protected-resource/orders`.
""".
-spec well_known_path(binary()) -> binary().
well_known_path(Resource) ->
    #{path := Path} = uri_string:parse(Resource),
    Suffix = unicode:characters_to_binary(string:trim(Path, trailing, "/")),
    <<"/.well-known/oauth-protected-resource", Suffix/binary>>.

-doc "The full URL of the document for `Resource`.".
-spec well_known_url(binary()) -> binary().
well_known_url(Resource) ->
    Parts = maps:without([query, fragment], uri_string:parse(Resource)),
    unicode:characters_to_binary(uri_string:recompose(Parts#{path => well_known_path(Resource)})).

dpop_fields(Binding, Opts) ->
    case livery_auth_binding:dpop_enabled(Opts) of
        true ->
            #{
                <<"dpop_signing_alg_values_supported">> =>
                    maps:get(algorithms, Opts, livery_auth_jose:algorithms()),
                <<"dpop_bound_access_tokens_required">> => Binding =:= dpop
            };
        false ->
            #{}
    end.
