%% @doc Exercises examples/livery_example_ws.erl end to end: boot the
%% example WebSocket service on an ephemeral H1 port, connect a real
%% client, and assert a text frame is echoed back.
-module(livery_example_ws_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

ws_echo_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Port) ->
        {timeout, 15, fun() -> echo(Port) end}
    end}.

setup() ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, Pid} = livery_example_ws:start(0),
    #{h1 := Port} = livery:which_listeners(Pid),
    put(service_pid, Pid),
    Port.

cleanup(_Port) ->
    ok = livery_example_ws:stop(erase(service_pid)).

echo(Port) ->
    Url = iolist_to_binary([
        <<"ws://127.0.0.1:">>, integer_to_binary(Port), <<"/">>
    ]),
    Self = self(),
    {ok, Sess} = ws_client:connect(Url, #{
        handler => livery_ws_client_capture,
        handler_opts => #{parent => Self}
    }),
    try
        ok = ws:send(Sess, [{text, <<"ping">>}]),
        Frame =
            receive
                {captured, F} -> F
            after 10000 -> error(no_ws_echo)
            end,
        ?assertEqual({text, <<"ping">>}, Frame)
    after
        catch ws:close(Sess, 1000, <<"bye">>),
        catch ws:stop(Sess)
    end.
