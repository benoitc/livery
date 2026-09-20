%% The agent behind livery_a2a_SUITE, trimmed from barrel_a2a's own
%% test agent. Behaviour is chosen by the text of the incoming message.
-module(livery_a2a_test_agent).

-behaviour(barrel_a2a_handler).

-export([handle_message/2, handle_cancel/1]).
-export([card/0]).

card() ->
    barrel_a2a_agent_card:new(#{
        name => <<"Test Agent">>,
        description => <<"Agent used by livery_a2a_SUITE">>,
        version => <<"1.2.3">>,
        default_input_modes => [<<"text/plain">>],
        default_output_modes => [<<"text/plain">>],
        skills => [
            #{
                id => <<"echo">>,
                name => <<"Echo">>,
                description => <<"Echoes text back">>,
                tags => [<<"test">>]
            }
        ]
    }).

handle_message(Ctx, Message) ->
    Text = barrel_a2a_message:text(Message),
    case barrel_a2a_ctx:is_follow_up(Ctx) of
        true -> {ok, <<"thanks: ", Text/binary>>};
        false -> dispatch(Text, Ctx)
    end.

dispatch(<<"echo: ", Rest/binary>>, _Ctx) ->
    {ok, Rest};
dispatch(<<"stream">>, Ctx) ->
    ok = barrel_a2a_ctx:status(Ctx, working, #{message => <<"starting">>}),
    ok = barrel_a2a_ctx:artifact(Ctx, <<"part one ">>, #{artifact_id => <<"a1">>, name => <<"out">>}),
    ok = barrel_a2a_ctx:artifact(Ctx, <<"part two">>, #{
        artifact_id => <<"a1">>, append => true, last_chunk => true
    }),
    ok;
dispatch(<<"slow ", Ms/binary>>, _Ctx) ->
    timer:sleep(binary_to_integer(Ms)),
    {ok, <<"done">>};
dispatch(<<"cancel-me">>, Ctx) ->
    ok = barrel_a2a_ctx:status(Ctx, working),
    wait_cancel(Ctx, 200);
dispatch(<<"ask">>, _Ctx) ->
    {input_required, <<"more?">>};
dispatch(<<"principal">>, Ctx) ->
    {ok, iolist_to_binary(io_lib:format("~0p", [barrel_a2a_ctx:principal(Ctx)]))};
dispatch(Other, _Ctx) ->
    {ok, <<"unknown: ", Other/binary>>}.

wait_cancel(_Ctx, 0) ->
    {ok, <<"never cancelled">>};
wait_cancel(Ctx, N) ->
    case barrel_a2a_ctx:cancelled(Ctx) of
        true ->
            notify_sink(cancelled_seen),
            ok;
        false ->
            timer:sleep(50),
            wait_cancel(Ctx, N - 1)
    end.

handle_cancel(_Ctx) ->
    notify_sink(handle_cancel_called),
    ok.

notify_sink(Msg) ->
    case whereis(livery_a2a_test_sink) of
        undefined -> ok;
        Pid -> Pid ! Msg
    end.
