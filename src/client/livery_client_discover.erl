-module(livery_client_discover).
-moduledoc """
Behaviour for resolving a balance pool's endpoints.

A provider turns some `Arg` into the list of endpoint base URLs the
balancer should spread across. The shipped provider,
`livery_client_discover_static`, just returns a fixed list; live
providers (periodic DNS, a registry watcher) can implement the same
callback later without touching the balancer.

The `endpoints` option of `livery_client:balance/1` is either a plain
list (sugar for the static provider) or `{Module, Arg}` naming a
provider.
""".

-export([resolve/1]).

-export_type([endpoints/0]).

-type endpoints() :: [binary()] | {module(), term()}.

-callback endpoints(Arg :: term()) -> [binary()].

-doc "Resolve an `endpoints` option to a concrete list of base URLs.".
-spec resolve(endpoints()) -> [binary()].
resolve({Module, Arg}) when is_atom(Module) ->
    Module:endpoints(Arg);
resolve(List) when is_list(List) ->
    List.
