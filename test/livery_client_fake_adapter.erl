%% @doc A no-socket client adapter, to prove the behaviour is pluggable.
-module(livery_client_fake_adapter).
-behaviour(livery_client_adapter).
-export([request/2]).

request(_Request, _Opts) ->
    {ok, #{status => 418, headers => [{<<"x-fake">>, <<"1">>}], body => {full, <<"teapot">>}}}.
