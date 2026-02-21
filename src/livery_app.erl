%% @doc Livery OTP application.
-module(livery_app).

-behaviour(application).

%% application callbacks
-export([start/2, stop/1]).

%% application callbacks

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    livery_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
