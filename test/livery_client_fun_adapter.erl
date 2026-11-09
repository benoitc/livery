%% @doc Client adapter for tests: answers every request with the `handler'
%% fun from its options, `fun((Request) -> {Status, Headers, Body})'.
-module(livery_client_fun_adapter).
-behaviour(livery_client_adapter).
-export([request/2]).

request(Request, #{handler := Handler}) ->
    {Status, Headers, Body} = Handler(Request),
    {ok, #{status => Status, headers => Headers, body => {full, Body}}}.
