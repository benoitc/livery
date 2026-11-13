%% livery_translator driven with plain messages: the test process plays
%% the request worker, a dummy process the connection, and the wire
%% events use the {Tag, Key, Event} shape every adapter's library sends.
-module(livery_translator_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TAG, wire).

%% Start a translator for the calling process. Returns what the test
%% needs to drive it and read what it sends.
start(Max) ->
    start(Max, none).

start(Max, OnAbandoned) ->
    Worker = self(),
    Conn = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    Key = make_ref(),
    BodyRef = make_ref(),
    DiscRef = make_ref(),
    Wire = #{
        tag => ?TAG,
        key => Key,
        classify => fun classify/1,
        conn => Conn,
        on_abandoned => OnAbandoned
    },
    Pid = spawn(fun() ->
        livery_translator:translate(Worker, #{
            body_ref => BodyRef,
            disc_ref => DiscRef,
            max_body => Max,
            wire => Wire
        })
    end),
    #{pid => Pid, conn => Conn, key => Key, body => BodyRef, disc => DiscRef}.

classify({chunk, Chunk, Fin}) -> {data, Chunk, Fin};
classify({trailers, T}) -> {trailers, T};
classify({reset, R}) -> {reset, R};
classify(_) -> ignore.

wire(#{pid := Pid, key := Key}, Event) ->
    Pid ! {?TAG, Key, Event}.

%% Everything the translator sent for the body so far, in order.
body_msgs(#{body := Ref}) ->
    receive
        {livery_body, Ref, Msg} -> [Msg | body_msgs(#{body => Ref})]
    after 100 -> []
    end.

disconnects(#{disc := Ref}) ->
    receive
        {livery_disconnect, Ref, Reason} -> [Reason | disconnects(#{disc => Ref})]
    after 100 -> []
    end.

%% The test process is the worker: ending the translator means exiting,
%% so run the scenario in a throwaway worker when the end matters.
as_worker(Fun) ->
    Parent = self(),
    {Pid, MRef} = spawn_monitor(fun() -> Parent ! {self(), Fun()} end),
    receive
        {Pid, Result} ->
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, Reason} ->
            error(Reason)
    end.

forwards_chunks_in_order_then_eof_test() ->
    T = start(infinity),
    wire(T, {chunk, <<"a">>, false}),
    wire(T, {chunk, <<"b">>, false}),
    wire(T, {chunk, <<"c">>, true}),
    ?assertEqual([{data, <<"a">>}, {data, <<"b">>}, {data, <<"c">>}, eof], body_msgs(T)).

empty_final_chunk_is_eof_test() ->
    T = start(infinity),
    wire(T, {chunk, <<"a">>, false}),
    wire(T, {chunk, <<>>, true}),
    ?assertEqual([{data, <<"a">>}, eof], body_msgs(T)).

forwards_trailers_test() ->
    T = start(infinity),
    wire(T, {trailers, [{<<"x">>, <<"1">>}]}),
    ?assertEqual([{trailers, [{<<"x">>, <<"1">>}]}], body_msgs(T)).

reset_reaches_reader_and_fires_once_test() ->
    T = start(infinity),
    wire(T, {reset, cancel}),
    wire(T, {reset, cancel}),
    ?assertEqual([{reset, cancel}, {reset, cancel}], body_msgs(T)),
    ?assertEqual([cancel], disconnects(T)).

connection_down_fires_once_test() ->
    #{conn := Conn} = T = start(infinity),
    Conn ! stop,
    %% `noproc' when the connection is gone before the monitor is set.
    ?assertMatch([{connection_closed, _}], disconnects(T)).

local_reset_is_not_a_disconnect_test() ->
    #{pid := Pid, disc := Disc} = T = start(infinity),
    Pid ! {livery_local_reset, Disc},
    wire(T, {reset, cancel}),
    ?assertEqual([{reset, cancel}], body_msgs(T)),
    ?assertEqual([], disconnects(T)).

late_disconnect_callback_still_runs_test() ->
    #{pid := Pid, disc := Disc} = T = start(infinity),
    wire(T, {reset, cancel}),
    ?assertEqual([cancel], disconnects(T)),
    Self = self(),
    Pid ! {livery_on_disconnect, Disc, fun() -> Self ! late_callback end},
    receive
        late_callback -> ok
    after 1000 -> error(callback_not_run)
    end.

over_limit_reports_once_and_drops_the_rest_test() ->
    T = start(4),
    wire(T, {chunk, <<"abc">>, false}),
    wire(T, {chunk, <<"defg">>, false}),
    wire(T, {chunk, <<"hij">>, false}),
    wire(T, {chunk, <<"klm">>, true}),
    ?assertEqual([{data, <<"abc">>}, {error, body_too_large}], body_msgs(T)).

on_abandoned_runs_while_client_still_sends_test() ->
    Self = self(),
    as_worker(fun() ->
        T = start(4, fun() -> Self ! abandoned end),
        wire(T, {chunk, <<"too long">>, false}),
        body_msgs(T),
        ok
    end),
    receive
        abandoned -> ok
    after 1000 -> error(on_abandoned_not_run)
    end.

on_abandoned_skipped_when_client_finished_test() ->
    Self = self(),
    as_worker(fun() ->
        T = start(4, fun() -> Self ! abandoned end),
        wire(T, {chunk, <<"too long">>, true}),
        body_msgs(T),
        ok
    end),
    receive
        abandoned -> error(on_abandoned_ran)
    after 200 -> ok
    end.

on_abandoned_skipped_after_normal_end_test() ->
    Self = self(),
    as_worker(fun() ->
        T = start(infinity, fun() -> Self ! abandoned end),
        wire(T, {chunk, <<"ok">>, true}),
        body_msgs(T),
        ok
    end),
    receive
        abandoned -> error(on_abandoned_ran)
    after 200 -> ok
    end.

ignored_event_is_consumed_test() ->
    #{pid := Pid} = T = start(infinity),
    wire(T, {goaway, 0}),
    wire(T, {chunk, <<"a">>, true}),
    ?assertEqual([{data, <<"a">>}, eof], body_msgs(T)),
    ?assertEqual({message_queue_len, 0}, process_info(Pid, message_queue_len)).

other_key_stays_in_the_mailbox_test() ->
    #{pid := Pid} = T = start(infinity),
    Pid ! {?TAG, make_ref(), {chunk, <<"not mine">>, true}},
    wire(T, {chunk, <<"mine">>, true}),
    ?assertEqual([{data, <<"mine">>}, eof], body_msgs(T)),
    ?assertEqual({message_queue_len, 1}, process_info(Pid, message_queue_len)).

split_query_test() ->
    ?assertEqual({<<"/a">>, <<"b=1">>}, livery_translator:split_query(<<"/a?b=1">>)),
    ?assertEqual({<<"/a">>, <<>>}, livery_translator:split_query(<<"/a">>)).
