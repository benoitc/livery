%% @doc Top-level supervisor for Livery.
-module(livery_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_listener/2, stop_listener/1]).

%% supervisor callbacks
-export([init/1]).

%% API

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a new listener.
-spec start_listener(atom(), map()) -> {ok, pid()} | {error, term()}.
start_listener(Name, Opts) ->
    ChildSpec = #{
        id => Name,
        start => {livery_acceptor_sup, start_link, [Opts]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [livery_acceptor_sup]
    },
    supervisor:start_child(?MODULE, ChildSpec).

%% @doc Stop a listener.
-spec stop_listener(atom()) -> ok | {error, term()}.
stop_listener(Name) ->
    case supervisor:terminate_child(?MODULE, Name) of
        ok ->
            supervisor:delete_child(?MODULE, Name);
        Error ->
            Error
    end.

%% supervisor callbacks

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    {ok, {SupFlags, []}}.
