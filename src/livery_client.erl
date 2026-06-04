-module(livery_client).
-moduledoc """
A composable HTTP client: the outbound twin of the server middleware.

Build a client once with `new/1` (a transport adapter, a base URL,
default headers, and a layer stack), then call it with `get/2`, `post/3`,
`request/3,4`. Layers run outermost-first and each is
`call(Request, Next, State) -> {ok, response()} | {error, term()}`, the
same shape as server middleware, with errors threaded as values.

```erlang
Client = livery_client:new(#{
    base_url => <<"https://api.example.com">>,
    stack    => [
        livery_client:timeout(5000),
        livery_client:retry(#{max => 3}),
        livery_client:circuit_breaker(#{name => api}),
        livery_client:concurrency(50)
    ]
}),
{ok, Resp} = livery_client:get(Client, <<"/users/42">>),
200 = livery_client:status(Resp).
```

The transport is a `livery_client_adapter`; the default,
`livery_client_hackney`, speaks HTTP/1.1, HTTP/2, and HTTP/3.
""".

-export([new/1]).
-export([get/2, post/3, put/3, delete/2, request/3, request/4, run/2]).
-export([status/1, headers/1, header/2, header/3, body/1, method/1, url/1, set_header/3]).
-export([read/2, read_body/1]).
-export([timeout/1, concurrency/1, retry/1, circuit_breaker/1, balance/1]).
-export([add_endpoint/2, remove_endpoint/2]).
-export([before/1, after_response/1, wrap/1]).
-export([rebase/2]).

-export_type([client/0, request/0, response/0, result/0, next/0, entry/0, stack/0, endpoint/0]).

-type request() :: #{
    method := atom() | binary(),
    url := binary(),
    headers := [{binary(), binary()}],
    body := empty | {full, iodata()} | {stream, fun()},
    timeout := timeout(),
    stream := boolean(),
    meta := map()
}.
-type response() :: #{
    status := 100..599,
    headers := [{binary(), binary()}],
    body := {full, binary()} | {stream, term()}
}.
-type result() :: {ok, response()} | {error, term()}.
-type endpoint() :: binary().
-type next() :: fun((request()) -> result()).
-type entry() :: {module(), term()} | fun((request(), next()) -> result()).
-type stack() :: [entry()].
-opaque client() :: #{
    adapter := module(),
    adapter_opts := map(),
    base_url := binary(),
    headers := [{binary(), binary()}],
    stack := stack()
}.

%%====================================================================
%% Build and call
%%====================================================================

-doc """
Build a client. Opts: `adapter` (default `livery_client_hackney`),
`adapter_opts`, `base_url`, `headers` (defaults applied to every
request), `stack` (the layers).
""".
-spec new(map()) -> client().
new(Opts) ->
    #{
        adapter => maps:get(adapter, Opts, livery_client_hackney),
        adapter_opts => maps:get(adapter_opts, Opts, #{}),
        base_url => maps:get(base_url, Opts, <<>>),
        headers => maps:get(headers, Opts, []),
        stack => maps:get(stack, Opts, [])
    }.

-spec get(client(), binary()) -> result().
get(Client, Path) -> request(Client, get, Path, #{}).

-spec post(client(), binary(), iodata()) -> result().
post(Client, Path, Body) -> request(Client, post, Path, #{body => {full, Body}}).

-spec put(client(), binary(), iodata()) -> result().
put(Client, Path, Body) -> request(Client, put, Path, #{body => {full, Body}}).

-spec delete(client(), binary()) -> result().
delete(Client, Path) -> request(Client, delete, Path, #{}).

-spec request(client(), atom() | binary(), binary()) -> result().
request(Client, Method, Path) -> request(Client, Method, Path, #{}).

-doc """
Send a request. `Opts`: `body` (`iodata` | `{full, _}` | `{stream, Fun}`),
`headers`, `timeout`, `stream` (`true` to receive a `{stream, Reader}`
response body), `meta`.
""".
-spec request(client(), atom() | binary(), binary(), map()) -> result().
request(Client, Method, Path, Opts) ->
    run(Client, build_request(Client, Method, Path, Opts)).

-doc "Run a fully built request through the client's layer stack.".
-spec run(client(), request()) -> result().
run(Client, Req) ->
    #{adapter := Adapter, adapter_opts := AdapterOpts, stack := Stack} = Client,
    Handler = fun(R) -> Adapter:request(R, AdapterOpts) end,
    run_stack(Stack, Handler, Req).

%%====================================================================
%% Accessors
%%====================================================================

-spec status(response()) -> 100..599.
status(#{status := S}) -> S.

-spec headers(request() | response()) -> [{binary(), binary()}].
headers(#{headers := H}) -> H.

-spec header(binary(), request() | response()) -> binary() | undefined.
header(Name, Map) -> header(Name, Map, undefined).

-spec header(binary(), request() | response(), Default) -> binary() | Default.
header(Name, #{headers := H}, Default) ->
    L = string:lowercase(Name),
    case lists:search(fun({K, _}) -> string:lowercase(K) =:= L end, H) of
        {value, {_, V}} -> V;
        false -> Default
    end.

-spec body(response()) -> {full, binary()} | {stream, term()}.
body(#{body := B}) -> B.

-spec method(request()) -> atom() | binary().
method(#{method := M}) -> M.

-spec url(request()) -> binary().
url(#{url := U}) -> U.

-spec set_header(binary(), binary(), request()) -> request().
set_header(Name, Value, #{headers := H} = Req) ->
    L = string:lowercase(Name),
    Kept = [KV || {K, _} = KV <- H, string:lowercase(K) =/= L],
    Req#{headers => [{Name, Value} | Kept]}.

%%====================================================================
%% Streamed response bodies
%%====================================================================

-doc "Pull the next chunk of a `{stream, Reader}` response body.".
-spec read(term(), timeout()) -> {ok, binary(), term()} | {done, term()} | {error, term()}.
read({Adapter, State}, Timeout) ->
    case Adapter:read(State, Timeout) of
        {ok, Data, State1} -> {ok, Data, {Adapter, State1}};
        {done, State1} -> {done, {Adapter, State1}};
        {error, _} = E -> E
    end.

-doc "Drain a `{stream, Reader}` response body to a single binary.".
-spec read_body(term()) -> {ok, binary()} | {error, term()}.
read_body(Reader) -> read_body(Reader, []).

read_body(Reader, Acc) ->
    case read(Reader, 30000) of
        {ok, Data, Reader1} -> read_body(Reader1, [Data | Acc]);
        {done, _Reader1} -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {error, _} = E -> E
    end.

%%====================================================================
%% Layer constructors
%%====================================================================

-spec timeout(pos_integer()) -> entry().
timeout(Ms) -> {livery_client_timeout, Ms}.

-spec concurrency(non_neg_integer()) -> entry().
concurrency(Limit) -> {livery_client_concurrency, livery_client_concurrency:limiter(Limit)}.

-spec retry(map()) -> entry().
retry(Opts) -> {livery_client_retry, Opts}.

-spec circuit_breaker(map()) -> entry().
circuit_breaker(Opts) -> {livery_client_circuit, Opts}.

-doc """
Spread requests across a pool of endpoints, with passive outlier
ejection and lazy half-open recovery. `Opts`: `name` (required),
`endpoints` (base URLs or a `{Module, Arg}` discovery pair), `policy`
(`p2c` | `round_robin`), `eject_after`, `eject_for`, `fail_status`.
With `balance` you pass paths; the chosen endpoint supplies the host.
""".
-spec balance(map()) -> entry().
balance(Opts) -> {livery_client_balance, Opts}.

-doc "Add an endpoint to a balance pool at runtime.".
-spec add_endpoint(term(), endpoint()) -> ok.
add_endpoint(Name, Endpoint) -> livery_client_balance_store:add(Name, Endpoint).

-doc "Remove an endpoint from a balance pool at runtime.".
-spec remove_endpoint(term(), endpoint()) -> ok.
remove_endpoint(Name, Endpoint) -> livery_client_balance_store:remove(Name, Endpoint).

%%====================================================================
%% Sugar (mirrors livery_middleware, error-aware)
%%====================================================================

-spec before(fun((request()) -> request())) -> entry().
before(Fun) when is_function(Fun, 1) ->
    fun(Req, Next) -> Next(Fun(Req)) end.

-spec after_response(fun((response()) -> response())) -> entry().
after_response(Fun) when is_function(Fun, 1) ->
    fun(Req, Next) ->
        case Next(Req) of
            {ok, Resp} -> {ok, Fun(Resp)};
            {error, _} = E -> E
        end
    end.

-spec wrap(fun((throw | error | exit, term(), list()) -> result())) -> entry().
wrap(Fun) when is_function(Fun, 3) ->
    fun(Req, Next) ->
        try
            Next(Req)
        catch
            Class:Reason:Stack -> Fun(Class, Reason, Stack)
        end
    end.

%%====================================================================
%% Internals
%%====================================================================

build_request(Client, Method, Path, Opts) ->
    #{
        method => Method,
        url => full_url(Client, Path),
        headers => merge_headers(maps:get(headers, Client), maps:get(headers, Opts, [])),
        body => normalize_body(maps:get(body, Opts, empty)),
        timeout => maps:get(timeout, Opts, 30000),
        stream => maps:get(stream, Opts, false),
        meta => maps:get(meta, Opts, #{})
    }.

run_stack([], Handler, Req) ->
    Handler(Req);
run_stack([Entry | Rest], Handler, Req) ->
    Next = fun(R) -> run_stack(Rest, Handler, R) end,
    call_entry(Entry, Req, Next).

call_entry({Mod, State}, Req, Next) when is_atom(Mod) ->
    Mod:call(Req, Next, State);
call_entry(Fun, Req, Next) when is_function(Fun, 2) ->
    Fun(Req, Next).

normalize_body(empty) -> empty;
normalize_body({full, _} = B) -> B;
normalize_body({stream, _} = B) -> B;
normalize_body(IoData) -> {full, IoData}.

full_url(Client, Path) ->
    case maps:get(base_url, Client) of
        <<>> -> Path;
        Base -> <<(strip_trailing_slash(Base))/binary, (ensure_leading_slash(Path))/binary>>
    end.

-doc """
Point a request URL at a chosen endpoint. Strips any scheme+authority
the URL already carries and joins the endpoint with the remaining
path+query, so the balancer owns the host. Used by `livery_client_balance`.
""".
-spec rebase(endpoint(), binary()) -> binary().
rebase(Endpoint, Url) ->
    Path = path_and_query(Url),
    <<(strip_trailing_slash(Endpoint))/binary, Path/binary>>.

%% The path+query of a URL, dropping scheme+authority if present.
path_and_query(Url) ->
    case binary:match(Url, <<"://">>) of
        nomatch ->
            ensure_leading_slash(Url);
        {Start, Len} ->
            Rest = binary_from(Url, Start + Len),
            case binary:match(Rest, <<"/">>) of
                nomatch -> <<"/">>;
                {Slash, _} -> binary_from(Rest, Slash)
            end
    end.

binary_from(Bin, Pos) ->
    binary:part(Bin, Pos, byte_size(Bin) - Pos).

strip_trailing_slash(B) ->
    case binary:last(B) of
        $/ -> binary:part(B, 0, byte_size(B) - 1);
        _ -> B
    end.

ensure_leading_slash(<<$/, _/binary>> = P) -> P;
ensure_leading_slash(P) -> <<$/, P/binary>>.

%% Default headers are overridden by per-request headers of the same name.
merge_headers(Defaults, Extra) ->
    Names = [string:lowercase(N) || {N, _} <- Extra],
    Kept = [KV || {N, _} = KV <- Defaults, not lists:member(string:lowercase(N), Names)],
    Kept ++ Extra.
