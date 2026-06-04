# How to serve MCP tools

## Problem

You want your tools, resources, and prompts to be reachable by MCP
clients - Claude, an IDE, an agent - and you would rather serve them
from the same Livery service that already handles your other routes,
not a separate process. The MCP Streamable HTTP transport is how
those clients talk to you, and this guide wires it up.

## Solution

`livery_mcp:handler/1` bridges Livery to the `barrel_mcp` protocol
engine. The split is clean: Livery owns the wire (H1/H2/H3, router,
middleware), and the engine handles the MCP protocol itself (POST
requests, GET SSE streams, DELETE session termination). Mount it at
`/mcp`:

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

Tools live in the shared `barrel_mcp_registry`. You register them
through `barrel_mcp`'s own API; `livery_mcp` deliberately does not
wrap it:

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

You do not need to start anything by hand: `barrel_mcp` comes up
automatically as a Livery dependency, so the registry is ready the
moment your release boots.

## Options

`handler/1` accepts a map:

| Key | Default | Meaning |
|---|---|---|
| `session_enabled` | `true` | Use `Mcp-Session-Id` sessions |
| `auth` | none | A `barrel_mcp` auth provider config |
| `allowed_origins` | `any` | `any` or a list of allowed `Origin`s |
| `allow_missing_origin` | `true` | Accept requests with no `Origin` |
| `resource_metadata` | none | OAuth protected-resource-metadata |

If you are deploying this publicly, do set `allowed_origins` to your
real client origins. It is your guard against DNS-rebinding, and the
default `any` is too trusting for the open internet.

## Notes

- The handler writes the response straight to the wire and returns
  the `taken_over` sentinel, so do not stack response-mutating
  middleware after it. It has already left the building.
- The same handler serves all three protocols. Mount it once on a
  multi-protocol service and MCP rides H2/H3 for free.

## See also

- Reference: `livery_mcp`, and the `barrel_mcp` docs for the tool/
  resource/prompt registry and auth providers.
- Concept: [Routing](../concepts/routing.md)
