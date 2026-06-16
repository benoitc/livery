-module(livery_client_cookie_store).
-moduledoc """
Behaviour for the cookie jar's backing store.

`livery_client_cookie` keeps no cookies of its own; it reads and writes
them through this behaviour. The default, `livery_client_cookie_store_ets`,
holds them in a public ETS table created by the jar constructor and shared
across the concurrent request processes that run the client. Implement the
four callbacks to back a jar with something else (a shared process, an
external cache); the jar stays in-memory and per-jar either way.

Cookies and keys are opaque to the store: it persists and returns them
without looking inside.

- `init(Opts) -> Store` - build the store from the `jar/1` opts and return
  an opaque handle.
- `get(Store) -> [Cookie]` - every cookie currently held, in any order.
- `put(Store, Key, Cookie) -> ok` - store `Cookie` under `Key`, replacing
  any cookie already there.
- `delete(Store, Key) -> ok` - forget the cookie under `Key`.
""".

-export_type([store/0, cookie/0, key/0]).

-type store() :: term().
-type cookie() :: term().
-type key() :: term().

-callback init(Opts :: map()) -> store().
-callback get(store()) -> [cookie()].
-callback put(store(), key(), cookie()) -> ok.
-callback delete(store(), key()) -> ok.
