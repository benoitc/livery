-module(livery_client_cookie_store_ets).
-moduledoc """
The default cookie jar store: a public ETS table.

`livery_client:cookie_jar/0,1` uses it implicitly, so you rarely name it
directly. The constructor creates one unnamed `public` table per jar and
hands it back as the opaque store handle; every request process that runs
the client reads and writes the same table. The table is owned by the
process that built the jar, so build the jar under a process that outlives
its requests.
""".
-behaviour(livery_client_cookie_store).

-export([init/1, get/1, put/3, delete/2]).

-spec init(map()) -> ets:tid().
init(_Opts) ->
    ets:new(livery_client_cookies, [
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]).

-spec get(ets:tid()) -> [livery_client_cookie_store:cookie()].
get(Tab) ->
    [Cookie || {_Key, Cookie} <- ets:tab2list(Tab)].

-spec put(ets:tid(), livery_client_cookie_store:key(), livery_client_cookie_store:cookie()) -> ok.
put(Tab, Key, Cookie) ->
    true = ets:insert(Tab, {Key, Cookie}),
    ok.

-spec delete(ets:tid(), livery_client_cookie_store:key()) -> ok.
delete(Tab, Key) ->
    true = ets:delete(Tab, Key),
    ok.
