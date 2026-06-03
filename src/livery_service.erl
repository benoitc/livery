-module(livery_service).
-moduledoc """
Service runtime.

Brings up H3 on UDP, H2 on TLS, and H1 on TCP under one
supervisor, sharing one router/middleware/handler. Optionally
advertises Alt-Svc on H1 and H2 responses so clients race up to
H3.

Configuration map:

```
livery:start_service(#{
    host       => <<"example.com">>,
    http3      => #{port => 443, cert => Cert, key => Key},
    https      => #{port => 443, cert => Cert, key => Key},
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
    alt_svc => advertise | none
}.

-type listener_opts() :: #{
    port => inet:port_number(),
    %% Bind address. An IPv6 8-tuple selects the inet6 family.
    ip => inet:ip_address(),
    %% Bind the IPv6 wildcard (`::') when no explicit `ip' is given.
    inet6 => boolean(),
    cert => binary() | string(),
    key => binary() | string() | term(),
    cacerts => [binary()],
    acceptors => pos_integer(),
    settings => map(),
    quic_opts => map()
}.

-record(state, {
    h1 :: {livery_h1:listener(), inet:port_number()} | undefined,
    h2 :: {livery_h2:listener(), inet:port_number()} | undefined,
    h3 :: {livery_h3:listener(), inet:port_number()} | undefined
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
present only for protocols that were configured.
""".
-spec which_listeners(pid()) -> #{h1 | h2 | h3 => inet:port_number()}.
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
        H1 = maybe_start_h1(Opts, Stack, Handler),
        H2 = maybe_start_h2(Opts, Stack, Handler),
        {ok, #state{h1 = H1, h2 = H2, h3 = H3}}
    catch
        throw:Reason ->
            {stop, Reason};
        Class:Reason ->
            {stop, {Class, Reason}}
    end.

-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}}.
handle_call(stop_accepting, _From, State) ->
    _ = stop_h3(State#state.h3),
    _ = stop_h2(State#state.h2),
    _ = stop_h1(State#state.h1),
    {reply, ok, State#state{h1 = undefined, h2 = undefined, h3 = undefined}};
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
    _ = stop_h3(State#state.h3),
    _ = stop_h2(State#state.h2),
    _ = stop_h1(State#state.h1),
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

-spec build_stack(
    service_opts(),
    {atom(), inet:port_number()} | undefined
) ->
    livery_middleware:stack().
build_stack(Opts, H3) ->
    User = base_stack(Opts),
    case {maps:get(alt_svc, Opts, none), H3} of
        {advertise, {_Name, Port}} ->
            [{livery_alt_svc, #{value => alt_svc_header(Port)}} | User];
        _ ->
            User
    end.

-spec alt_svc_header(inet:port_number()) -> binary().
alt_svc_header(Port) ->
    iolist_to_binary([
        <<"h3=\":">>,
        integer_to_binary(Port),
        <<"\"; ma=86400">>
    ]).

maybe_start_h1(Opts, Stack, Handler) ->
    case maps:find(http, Opts) of
        {ok, ListenOpts} ->
            ListenOpts1 = maps:merge(
                ListenOpts,
                #{stack => Stack, handler => Handler}
            ),
            {ok, Ref} = livery_h1:start(ListenOpts1),
            {Ref, h1:server_port(Ref)};
        error ->
            undefined
    end.

maybe_start_h2(Opts, Stack, Handler) ->
    case maps:find(https, Opts) of
        {ok, ListenOpts} ->
            ListenOpts1 = maps:merge(
                ListenOpts,
                #{
                    stack => Stack,
                    handler => Handler,
                    transport => maps:get(
                        transport,
                        ListenOpts,
                        ssl
                    )
                }
            ),
            {ok, Ref} = livery_h2:start(ListenOpts1),
            {Ref, h2:server_port(Ref)};
        error ->
            undefined
    end.

maybe_start_h3(Opts, Stack, Handler) ->
    case maps:find(http3, Opts) of
        {ok, ListenOpts} ->
            ListenOpts1 = ensure_h3_name(
                maps:merge(
                    ListenOpts,
                    #{stack => Stack, handler => Handler}
                )
            ),
            {ok, Name} = livery_h3:start(ListenOpts1),
            {ok, Port} = quic:get_server_port(Name),
            {Name, Port};
        error ->
            undefined
    end.

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

stop_h1(undefined) -> ok;
stop_h1({Ref, _Port}) -> livery_h1:stop(Ref).

stop_h2(undefined) -> ok;
stop_h2({Ref, _Port}) -> livery_h2:stop(Ref).

stop_h3(undefined) -> ok;
stop_h3({Name, _Port}) -> livery_h3:stop(Name).

listeners_map(State) ->
    Acc0 = #{},
    Acc1 =
        case State#state.h1 of
            undefined -> Acc0;
            {_, P1} -> Acc0#{h1 => P1}
        end,
    Acc2 =
        case State#state.h2 of
            undefined -> Acc1;
            {_, P2} -> Acc1#{h2 => P2}
        end,
    case State#state.h3 of
        undefined -> Acc2;
        {_, P3} -> Acc2#{h3 => P3}
    end.
