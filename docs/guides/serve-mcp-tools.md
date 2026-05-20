# How to serve MCP tools

## Problem

You want to expose tools, resources, and prompts to MCP clients
(Claude, IDEs, agents) over the MCP Streamable HTTP transport,
served by your Livery service alongside your other routes.

## Solution

`livery_mcp:handler/1` bridges Livery to the `barrel_mcp` protocol
engine. Livery owns the wire (H1/H2/H3, router, middleware); the
engine handles the MCP protocol (POST requests, GET SSE streams,
DELETE session termination). Mount it at `/mcp`:

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

The `barrel_mcp` application is started automatically as a Livery
dependency, so the registry is ready once your release boots.

## Options

`handler/1` accepts a map:

| Key | Default | Meaning |
|---|---|---|
| `session_enabled` | `true` | Use `Mcp-Session-Id` sessions |
| `auth` | none | A `barrel_mcp` auth provider config |
| `allowed_origins` | `any` | `any` or a list of allowed `Origin`s |
| `allow_missing_origin` | `true` | Accept requests with no `Origin` |
| `resource_metadata` | none | OAuth protected-resource-metadata |

For public deployments, set `allowed_origins` to your client
origins to guard against DNS-rebinding.

## Notes

- The handler writes the response straight to the wire and returns
  the `taken_over` sentinel, so do not stack response-mutating
  middleware after it.
- The same handler serves all three protocols; mount it once on a
  multi-protocol service and MCP rides H2/H3 automatically.

## See also

- Reference: `livery_mcp`, and the `barrel_mcp` docs for the tool/
  resource/prompt registry and auth providers.
- Concept: [Routing](../concepts/routing.md)
