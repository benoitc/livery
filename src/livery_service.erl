-module(livery_service).
-moduledoc """
Service runtime.

Brings up H3 on UDP, H2 on TLS, and H1 on TCP under one
supervisor, sharing one router/middleware/handler. Optionally
advertises Alt-Svc on H1 and H2 responses so clients race up to
H3.

The `https` listener is h2-only by default; `alpn => [h2, http1]`
makes it serve HTTP/2 and HTTP/1.1 from the same port, chosen per
connection.

Configuration map:

```
livery:start_service(#{
    host       => <<"example.com">>,
    http3      => #{port => 443, cert => Cert, key => Key},
    https      => #{port => 443, cert => Cert, key => Key,
                    alpn => [h2, http1]},
    http       => #{port => 80},
    handler    => fun handler/1,
    middleware => Stack,
    alt_svc    => advertise
}).
```

Supply exactly one of `handler` (a single catch-all) or `router`
(a compiled `livery_router` the service dispatches through, via
`livery:router_handler/1`).

Returns `{ok, ServicePid}`. The service pid owns the listeners and
shuts them down when stopped via `livery:stop_service/1`. A crash
takes them all down together. For a polite shutdown that lets
in-flight requests finish, use `livery:drain/1,2`.
""".
-behaviour(gen_server).

-include("livery.hrl").

-export([
    start_link/1,
    stop/1,
    stop_accepting/1,
    which_listeners/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export_type([service_opts/0]).

-type service_opts() :: #{
    host => binary(),
    http => listener_opts(),
    https => listener_opts(),
    http3 => listener_opts(),
    %% Supply exactly one of `handler' (a catch-all) or `router' (a
    %% compiled livery_router that the service dispatches through).
    handler => livery_middleware:handler(),
    router => livery_router:router(),
    middleware => livery_middleware:stack(),
    %% Shared service config, readable in handlers via livery_req:config/1.
    %% A per-listener `config' (in the http/https/http3 map) overrides it.
    config => term(),
    alt_svc => advertise | none
}.

%% Per-listener options. The keys below are the ones that mean something
%% on more than one listener; anything else in the map is forwarded
%% verbatim to the adapter that ends up serving the key, so
%% `livery_h1:listen_opts()', `livery_h2:listen_opts()',
%% `livery_h1h2:listen_opts()', and `livery_h3:listen_opts()' are the
%% full lists (h1's parser size limits, h3's `quic_opts', and so on).
-type listener_opts() :: #{
    %% HTTP/3 listener name (atom); auto-derived from the port if absent.
    name => atom(),
    port => inet:port_number(),
    %% Bind address. An IPv6 8-tuple selects the inet6 family.
    ip => inet:ip_address(),
    %% Bind the IPv6 wildcard (`::') when no explicit `ip' is given.
    inet6 => boolean(),
    %% Override the default transport for the key: `http' defaults to
    %% `tcp' and `https' to `ssl'. The useful one is h2c, which is
    %% `https' with `transport => tcp' and no certificates.
    transport => tcp | ssl,
    cert => binary() | string(),
    key => binary() | string() | term(),
    cacerts => [binary()],
    %% Client-certificate policy on the H1/H2 listeners. `verify_peer'
    %% requires `cacerts' and makes the certificate mandatory.
    verify => verify_none | verify_peer,
    ssl_opts => [ssl:tls_server_option()],
    %% `https' only: the protocols to advertise over ALPN, most preferred
    %% first. Defaults to `[h2]', an h2-only listener. `[h2, http1]' puts
    %% HTTP/2 and HTTP/1.1 on the same TLS port, chosen per connection.
    alpn => [livery_h1h2:protocol()],
    acceptors => pos_integer(),
    handshake_timeout => timeout(),
    %% Slow-client guards on the H1 listener; see `livery_h1:listen_opts()'.
    idle_timeout => timeout(),
    request_timeout => timeout(),
    max_keepalive_requests => pos_integer() | infinity,
    %% RFC 8441 extended CONNECT on the H2 listener.
    enable_connect_protocol => boolean(),
    %% Request-body ceiling. A body past this yields a graceful 413;
    %% `infinity' disables it, default 16 MiB. Honored by all three adapters;
    %% the H1 adapter enforces it in place of h1's own parser cap, so a value
    %% above h1's 8 MiB default takes effect instead of being silently capped.
    max_body => non_neg_integer() | infinity,
    %% H3 per-SNI certificate selection, forwarded to `quic' (>= 1.6.5).
    sni_callback => fun(
        (binary() | undefined) ->
            {ok, #{cert := binary(), key := term(), cert_chain => [binary()]}}
            | {error, term()}
    ),
    %% H2/H3 SETTINGS overrides.
    settings => map(),
    quic_opts => map(),
    %% HTTP/1.1 early-response inbound-drain budget (lingering close).
    %% See `livery_h1' `listen_opts()'. `lingering_timeout => Ms' is the
    %% time-only form. Ignored by the H2/H3 listeners.
    early_response_drain => 0 | {non_neg_integer() | infinity, non_neg_integer() | infinity},
    lingering_timeout => timeout(),
    %% Per-listener config; overrides the service-wide `config'.
    config => term()
}.

%% One entry per listen socket, not per protocol: an ALPN listener serves
%% both `h1' and `h2' from a single port, so `protocols' is a list.
-record(listener, {
    mod :: livery_h1 | livery_h2 | livery_h3 | livery_h1h2,
    ref :: term(),
    port :: inet:port_number(),
    protocols :: [h1 | h2 | h3]
}).

-record(state, {
    listeners = [] :: [#listener{}]
}).

-define(SERVER, ?MODULE).

%%====================================================================
%% Public API
%%====================================================================

-doc "Start a service from a config map.".
-spec start_link(service_opts()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-doc "Stop a running service.".
-spec stop(pid()) -> ok.
stop(Pid) when is_pid(Pid) ->
    gen_server:stop(Pid).

-doc """
Stop the service's listeners (no new connections) while leaving
the gen_server and any in-flight requests running. Used by
`livery_drain` to begin a graceful shutdown.
""".
-spec stop_accepting(pid()) -> ok.
stop_accepting(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, stop_accepting).

-doc """
Return the ports the service is bound to, by protocol. Keys are
present only for protocols that were configured, and each maps to
every port serving that protocol: an ALPN listener puts one port
under both `h1` and `h2`, and a cleartext `http` listener alongside
it gives `h1` two.
""".
-spec which_listeners(pid()) -> #{h1 | h2 | h3 => [inet:port_number()]}.
which_listeners(Pid) ->
    gen_server:call(Pid, which_listeners).

%%====================================================================
%% gen_server callbacks
%%====================================================================

-spec init(service_opts()) -> {ok, #state{}} | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    try
        Handler = resolve_handler(Opts),
        %% Start H3 first so the bound UDP port is known before
        %% building the Alt-Svc value used by H1 and H2.
        H3 = maybe_start_h3(Opts, base_stack(Opts), Handler),
        Stack = build_stack(Opts, H3),
        Listeners =
            H3 ++
                maybe_start_http(Opts, Stack, Handler) ++
                maybe_start_https(Opts, Stack, Handler),
        {ok, #state{listeners = Listeners}}
    catch
        throw:Reason ->
            {stop, Reason};
        Class:Reason ->
            {stop, {Class, Reason}}
    end.

-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}}.
handle_call(stop_accepting, _From, State) ->
    %% Listeners that can keep serving what they already accepted do so,
    %% and stay in the state so terminate/2 closes them once the drain
    %% ends. The H2 and H3 libraries have no stop-accepting, so those
    %% stop outright and drop out.
    Kept = lists:foldr(
        fun(L, Acc) ->
            case drain_listener(L) of
                keep -> [L | Acc];
                drop -> Acc
            end
        end,
        [],
        State#state.listeners
    ),
    {reply, ok, State#state{listeners = Kept}};
handle_call(which_listeners, _From, State) ->
    {reply, listeners_map(State), State};
handle_call(_, _, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_, State) -> {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(_, State) -> {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, State) ->
    _ = [stop_listener(L) || L <- State#state.listeners],
    ok.

-spec code_change(term(), #state{}, term()) -> {ok, #state{}}.
code_change(_, State, _) -> {ok, State}.

%%====================================================================
%% Internals
%%====================================================================

%% Resolve the effective handler from the config: a compiled
%% `router' (dispatched via livery:router_handler/1) or a single
%% catch-all `handler'. Exactly one must be given.
-spec resolve_handler(service_opts()) -> livery_middleware:handler().
resolve_handler(Opts) ->
    case {maps:find(router, Opts), maps:find(handler, Opts)} of
        {{ok, _}, {ok, _}} -> throw(both_router_and_handler);
        {{ok, Router}, _} -> livery:router_handler(Router);
        {_, {ok, H}} -> H;
        {error, error} -> throw(no_handler_or_router)
    end.

-spec base_stack(service_opts()) -> livery_middleware:stack().
base_stack(Opts) ->
    maps:get(middleware, Opts, []).

-spec build_stack(service_opts(), [#listener{}]) ->
    livery_middleware:stack().
build_stack(Opts, H3) ->
    User = base_stack(Opts),
    case {maps:get(alt_svc, Opts, none), H3} of
        {advertise, [#listener{port = Port} | _]} ->
            Value = alt_svc_header(maps:get(host, Opts, undefined), Port),
            [{livery_alt_svc, #{value => Value}} | User];
        _ ->
            User
    end.

%% RFC 7838 alt-authority is `[uri-host] ":" port', so the service `host'
%% (when given) qualifies the advertised authority instead of leaving the
%% client to reuse the origin's.
-spec alt_svc_header(binary() | undefined, inet:port_number()) -> binary().
alt_svc_header(Host, Port) ->
    Authority =
        case Host of
            undefined -> <<>>;
            _ -> Host
        end,
    iolist_to_binary([
        <<"h3=\"">>,
        Authority,
        <<":">>,
        integer_to_binary(Port),
        <<"\"; ma=86400">>
    ]).

maybe_start_http(Opts, Stack, Handler) ->
    case maps:find(http, Opts) of
        {ok, ListenOpts} ->
            {ok, Ref} = livery_h1:start(listener_opts(Opts, ListenOpts, Stack, Handler)),
            [
                #listener{
                    mod = livery_h1,
                    ref = Ref,
                    port = h1:server_port(Ref),
                    protocols = [h1]
                }
            ];
        error ->
            []
    end.

%% `alpn' decides which library owns the TLS port. The default `[h2]' is
%% the historical behaviour, an h2-only listener; anything naming more
%% than one protocol goes to the multiplexing listener, which resolves
%% ALPN itself and hands each connection to h1 or h2.
maybe_start_https(Opts, Stack, Handler) ->
    case maps:find(https, Opts) of
        {ok, ListenOpts} ->
            Merged = listener_opts(Opts, ListenOpts, Stack, Handler),
            start_https(maps:get(alpn, ListenOpts, [h2]), Merged);
        error ->
            []
    end.

start_https([h2], Opts) ->
    {ok, Ref} = livery_h2:start(with_transport(Opts)),
    [#listener{mod = livery_h2, ref = Ref, port = h2:server_port(Ref), protocols = [h2]}];
start_https([http1], Opts) ->
    {ok, Ref} = livery_h1:start(with_transport(Opts)),
    [#listener{mod = livery_h1, ref = Ref, port = h1:server_port(Ref), protocols = [h1]}];
start_https(Alpn, Opts) ->
    {ok, Ref} = livery_h1h2:start(Opts#{alpn => Alpn}),
    [
        #listener{
            mod = livery_h1h2,
            ref = Ref,
            port = livery_h1h2:server_port(Ref),
            protocols = protocols(Alpn)
        }
    ].

protocols(Alpn) ->
    lists:usort([protocol(P) || P <- Alpn]).

protocol(h2) -> h2;
protocol(http1) -> h1.

with_transport(Opts) ->
    Opts#{transport => maps:get(transport, Opts, ssl)}.

maybe_start_h3(Opts, Stack, Handler) ->
    case maps:find(http3, Opts) of
        {ok, ListenOpts} ->
            Merged = ensure_h3_name(listener_opts(Opts, ListenOpts, Stack, Handler)),
            {ok, Name} = livery_h3:start(Merged),
            {ok, Port} = quic:get_server_port(Name),
            [#listener{mod = livery_h3, ref = Name, port = Port, protocols = [h3]}];
        error ->
            []
    end.

listener_opts(Opts, ListenOpts, Stack, Handler) ->
    maps:merge(
        ListenOpts,
        #{
            stack => Stack,
            handler => Handler,
            config => listener_config(Opts, ListenOpts)
        }
    ).

%% A per-listener `config' overrides the service-wide one.
-spec listener_config(service_opts(), listener_opts()) -> term().
listener_config(Opts, ListenOpts) ->
    maps:get(config, ListenOpts, maps:get(config, Opts, undefined)).

%% `quic_h3' registers the listener under an atom name. Derive a stable
%% one from the bound port so restarting a service reuses the same
%% (interned) atom instead of leaking a fresh atom each start. A random
%% port (0) keeps the per-start auto-generated name.
-spec ensure_h3_name(map()) -> map().
ensure_h3_name(#{name := _} = Opts) ->
    Opts;
ensure_h3_name(#{port := Port} = Opts) when is_integer(Port), Port > 0 ->
    Opts#{name => list_to_atom("livery_h3_p" ++ integer_to_list(Port))};
ensure_h3_name(Opts) ->
    Opts.

stop_listener(#listener{mod = livery_h1, ref = Ref}) -> livery_h1:stop(Ref);
stop_listener(#listener{mod = livery_h2, ref = Ref}) -> livery_h2:stop(Ref);
stop_listener(#listener{mod = livery_h3, ref = Ref}) -> livery_h3:stop(Ref);
stop_listener(#listener{mod = livery_h1h2, ref = Ref}) -> livery_h1h2:stop(Ref).

%% `keep' means the listener stopped accepting but is still serving what
%% it accepted, so it stays in the state for terminate/2 to close.
drain_listener(#listener{mod = livery_h1, ref = Ref}) ->
    livery_h1:stop_accepting(Ref),
    keep;
drain_listener(#listener{mod = livery_h1h2, ref = Ref}) ->
    livery_h1h2:stop_accepting(Ref),
    keep;
drain_listener(#listener{mod = livery_h2, ref = Ref}) ->
    livery_h2:stop(Ref),
    drop;
drain_listener(#listener{mod = livery_h3, ref = Ref}) ->
    livery_h3:stop(Ref),
    drop.

listeners_map(#state{listeners = Listeners}) ->
    lists:foldl(fun add_ports/2, #{}, Listeners).

add_ports(#listener{port = Port, protocols = Protocols}, Acc) ->
    lists:foldl(
        fun(Protocol, A) ->
            A#{Protocol => maps:get(Protocol, A, []) ++ [Port]}
        end,
        Acc,
        Protocols
    ).
