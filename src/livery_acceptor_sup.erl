%% @doc Supervisor for acceptor pool.
%%
%% Starts N acceptor processes, each with its own listen socket (SO_REUSEPORT).
-module(livery_acceptor_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% supervisor callbacks
-export([init/1]).

%% API

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    supervisor:start_link(?MODULE, Opts).

%% supervisor callbacks

-spec init(map()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Opts) ->
    NumAcceptors = get_num_acceptors(Opts),
    Port = maps:get(port, Opts),
    Handler = maps:get(handler, Opts),
    HandlerOpts = maps:get(handler_opts, Opts, []),
    SslOpts = maps:get(ssl_opts, Opts, []),

    AcceptorOpts = #{
        port => Port,
        handler => Handler,
        handler_opts => HandlerOpts,
        ssl_opts => SslOpts
    },

    AcceptorChildren = [
        #{
            id => {livery_acceptor, N},
            start => {livery_acceptor, start_link, [AcceptorOpts]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [livery_acceptor]
        }
        || N <- lists:seq(1, NumAcceptors)
    ],

    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },

    {ok, {SupFlags, AcceptorChildren}}.

%% Internal functions

-spec get_num_acceptors(map()) -> pos_integer().
get_num_acceptors(Opts) ->
    case maps:get(num_acceptors, Opts, auto) of
        auto ->
            erlang:system_info(schedulers);
        N when is_integer(N), N > 0 ->
            N
    end.
