# How to serve MCP tools

`livery_mcp:handler/1` exposes tools, resources, and prompts to MCP
clients (Claude, IDEs, agents) over the MCP Streamable HTTP
transport. You need it when you want those clients to reach your
tools alongside your other routes, on the same Livery service.

## Mount the handler

The handler bridges Livery to the `barrel_mcp` protocol engine.
Livery owns the wire (H1/H2/H3, router, middleware); the engine
handles the MCP protocol (POST requests, GET SSE streams, DELETE
session termination). Mount it at `/mcp`:

```erlang
Mcp = livery_mcp:handler(#{session_enabled => true}),
Router = livery_router:compile([
    {<<"POST">>,   <<"/mcp">>, Mcp},
    {<<"GET">>,    <<"/mcp">>, Mcp},
    {<<"DELETE">>, <<"/mcp">>, Mcp},
    {<<"OPTIONS">>,<<"/mcp">>, Mcp}
]),
livery:start_service(#{
    https  => #{port => 8443, cert => Cert, key => Key},
    router => Router
}).
```

## Register tools

Tools live in the shared `barrel_mcp_registry`. Register them with
`barrel_mcp`'s own API; `livery_mcp` does not wrap it:

```erlang
ok = barrel_mcp:reg_tool(<<"echo">>, my_tools, echo, #{
    description  => <<"Echo a value back">>,
    input_schema => #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{<<"value">> => #{<<"type">> => <<"string">>}}
    }
}).

%% my_tools:echo/1 receives the decoded arguments map.
echo(#{<<"value">> := V}) -> <<"echo: ", V/binary>>.
```

`barrel_mcp` is an optional application of Livery: Livery does not
fetch it for you. Add it to your own `rebar.config`:

```erlang
{deps, [livery, {barrel_mcp, "~> 4.3.0"}]}.
```

Then list it in your `.app.src` so the registry is ready once your
release boots:

```erlang
{applications, [kernel, stdlib, livery, barrel_mcp]}
```

## Options

`handler/1` accepts a map:

| Key | Default | Meaning |
|---|---|---|
| `session_enabled` | `true` | Use `Mcp-Session-Id` sessions |
| `auth` | none | A `barrel_mcp` auth provider config |
| `allowed_origins` | `any` | `any` or a list of allowed `Origin`s |
| `allow_missing_origin` | `true` | Accept requests with no `Origin` |
| `resource_metadata` | none | OAuth protected-resource-metadata |
| `sse_keepalive_ms` | `15000` | How often a quiet SSE stream emits a comment |
| `max_body_bytes` | 16 MiB | Request body cap, answered `413` past it |
| `body_timeout_ms` | `60000` | Wait for each body chunk, answered `408` past it |

The keepalive also falls back to the `barrel_mcp` `sse_keepalive_ms`
application env. Besides keeping proxies from dropping a stream, it is
what notices a client that went away without closing.

For public deployments, set `allowed_origins` to your client
origins to guard against DNS-rebinding.

## Require a bearer token

Pass a `barrel_mcp` auth provider under `auth`. The bearer provider
wants an `audience`: the resource your tokens are issued for, which is
your MCP endpoint.

```erlang
Mcp = livery_mcp:handler(#{
    auth => #{
        provider => barrel_mcp_auth_bearer,
        provider_opts => #{
            secret   => Secret,
            issuer   => <<"https://idp.example.com">>,
            audience => <<"https://api.example.com/mcp">>
        }
    }
}).
```

For RS256/ES256 or opaque tokens, give it a `verifier` fun instead of
a `secret`. `audience => any` skips the `aud` check, so since
`barrel_mcp` 4.0 it is only accepted together with a `verifier` that
checks the recipient itself.

The provider is initialised once, when you call `handler/1`. If it
refuses its options, `handler/1` raises
`{auth_provider, Module, Reason}` (for example
`audience_any_requires_verifier` or `{missing_option, audience}`), so
a bad config stops your service at boot and not on the first request.

## Tell clients how to use your server

Set `instructions` in the `barrel_mcp` application environment. It is
sent in the `initialize` result, and clients usually hand it to the
model:

```erlang
{barrel_mcp, [{instructions, <<"Search first, then fetch by id.">>}]}
```

## Decide what each caller sees

Your auth provider can filter list responses and subscriptions per
caller. Export these optional `barrel_mcp_auth` callbacks from your
provider module (or the module behind `barrel_mcp_auth_custom`):

```erlang
%% tools/list, resources/list, resources/templates/list, prompts/list
visible(tool, {<<"admin_", _/binary>>, _Handler}, AuthInfo, _State) ->
    lists:member(<<"admin">>, maps:get(scopes, AuthInfo, []));
visible(_Kind, _Entry, _AuthInfo, _State) ->
    true.

%% resources/subscribe and each URI of a subscriptions/listen filter
authorize_subscribe(AuthInfo, Uri, _State) ->
    is_owner(AuthInfo, Uri).
```

A hidden entry is left out of the list only: calls and reads are still
checked by your handlers. A refused subscription gets the same error
as a missing resource.

## Keep long tasks across restarts

Tasks live in ETS by default and a restart marks running ones failed.
To keep them, point `barrel_mcp` at a durable store, or let your
application own the task and register it as a provider:

```erlang
{barrel_mcp, [{task_store, my_task_store}, {task_store_opts, #{}}]}
```

```erlang
ok = barrel_mcp:reg_tool(<<"export">>, my_tools, export, #{
    task_support => optional,
    task_provider => my_export_tasks
}).

%% my_tools:export/2 starts the job and hands back its id.
export(Args, Ctx) ->
    case barrel_mcp:task_allowed(Ctx) of
        true ->
            Owner = barrel_mcp:task_owner(Ctx),
            {ok, Id} = my_exports:start(Args, Owner),
            {task, Id};
        false ->
            {ok, Id} = my_exports:start(Args, undefined),
            {structured, #{<<"export_id">> => Id}}
    end.
```

See the `barrel_mcp` durable tasks guide for the
`barrel_mcp_task_store` and `barrel_mcp_task_provider` behaviours.

## Notes

- The handler writes the response straight to the wire and returns
  the `taken_over` sentinel, so do not stack response-mutating
  middleware after it.
- Past one node, or if a restart must not interrupt a multi round-trip
  call, set `request_state_key` (32+ random bytes) in the `barrel_mcp`
  application environment. Without it a fresh key is generated at each
  boot and `barrel_mcp` logs a warning at start.
- The same handler serves all three protocols; mount it once on a
  multi-protocol service and MCP rides H2/H3 automatically.

## See also

- Reference: `livery_mcp`, and the `barrel_mcp` docs for the tool/
  resource/prompt registry and auth providers.
- Concept: [Routing](../concepts/routing.md)
