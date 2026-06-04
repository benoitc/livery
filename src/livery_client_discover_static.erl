-module(livery_client_discover_static).
-moduledoc """
The default discovery provider: a fixed list of endpoints.

`livery_client:balance/1` uses it implicitly when `endpoints` is a plain
list, so you rarely name it directly.
""".
-behaviour(livery_client_discover).

-export([endpoints/1]).

-spec endpoints([binary()]) -> [binary()].
endpoints(List) when is_list(List) -> List.
