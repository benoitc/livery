-module(livery).

-export([
    start_listener/2,
    stop_listener/1,
    start_service/1,
    stop_service/1,
    which_listeners/0
]).

-spec start_listener(atom(), map()) -> {ok, pid()} | {error, term()}.
start_listener(_Name, _Opts) ->
    {error, not_implemented}.

-spec stop_listener(atom()) -> ok | {error, term()}.
stop_listener(_Name) ->
    {error, not_implemented}.

-spec start_service(map()) -> {ok, pid()} | {error, term()}.
start_service(_Opts) ->
    {error, not_implemented}.

-spec stop_service(atom()) -> ok | {error, term()}.
stop_service(_Name) ->
    {error, not_implemented}.

-spec which_listeners() -> [atom()].
which_listeners() ->
    [].
