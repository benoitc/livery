%% @doc Exercises examples/livery_example_api.erl end to end: boot the
%% example service on an ephemeral H1 port and drive every route over
%% real HTTP with hackney.
-module(livery_example_api_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

api_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Port) ->
        {inorder, [
            {"index", fun() -> index(Port) end},
            {"greet binds the path param", fun() -> greet(Port) end},
            {"sse event stream", fun() -> events(Port) end},
            {"ndjson stream", fun() -> ticks(Port) end},
            {"openapi document", fun() -> openapi(Port) end}
        ]}
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(hackney),
    {ok, Pid} = livery_example_api:start(0),
    #{h1 := Port} = livery:which_listeners(Pid),
    put(service_pid, Pid),
    Port.

cleanup(_Port) ->
    ok = livery_example_api:stop(erase(service_pid)).

%%====================================================================
%% Route assertions
%%====================================================================

index(Port) ->
    {Status, CT, Body} = get(Port, <<"/">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"text/plain; charset=utf-8">>, CT),
    ?assertEqual(<<"hello, world">>, Body).

greet(Port) ->
    {Status, _CT, Body} = get(Port, <<"/hi/ada">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"hello, ada">>, Body).

events(Port) ->
    {Status, CT, Body} = get(Port, <<"/events">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"text/event-stream">>, CT),
    Expected = iolist_to_binary([
        ["event: tick\ndata: ", integer_to_binary(N), "\n\n"]
     || N <- lists:seq(1, 5)
    ]),
    ?assertEqual(Expected, Body).

ticks(Port) ->
    {Status, CT, Body} = get(Port, <<"/ticks">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"application/x-ndjson">>, CT),
    Lines = [L || L <- binary:split(Body, <<"\n">>, [global]), L =/= <<>>],
    ?assertEqual(5, length(Lines)),
    [?assertMatch(#{<<"n">> := _}, json:decode(L)) || L <- Lines].

openapi(Port) ->
    {Status, CT, Body} = get(Port, <<"/openapi.json">>),
    ?assertEqual(200, Status),
    ?assertEqual(<<"application/json">>, CT),
    ?assertMatch(#{<<"openapi">> := _, <<"paths">> := _}, json:decode(Body)).

%%====================================================================
%% Helpers
%%====================================================================

get(Port, Path) ->
    Url = iolist_to_binary([
        <<"http://127.0.0.1:">>, integer_to_binary(Port), Path
    ]),
    {ok, Status, Headers, Body} = hackney:request(
        get, Url, [], <<>>, [with_body, {recv_timeout, 10000}]
    ),
    {Status, content_type(Headers), Body}.

content_type(Headers) ->
    Lower = [{string:lowercase(to_bin(N)), to_bin(V)} || {N, V} <- Headers],
    case lists:keyfind(<<"content-type">>, 1, Lower) of
        {_, V} -> V;
        false -> undefined
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L).
