-module(livery_body_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

new_has_ref_test() ->
    R = livery_body:new(),
    ?assert(is_reference(livery_body:ref(R))),
    ?assertNot(livery_body:ended(R)),
    ?assertEqual(undefined, livery_body:source(R)),
    ?assertEqual(undefined, livery_body:trailers(R)).

read_pending_chunk_test() ->
    Ref = make_ref(),
    R = livery_body:new(Ref),
    self() ! {livery_body, Ref, {data, <<"hello">>}},
    ?assertMatch({ok, <<"hello">>, _}, livery_body:read(R, 0)).

read_eof_test() ->
    Ref = make_ref(),
    R = livery_body:new(Ref),
    self() ! {livery_body, Ref, eof},
    {done, R1} = livery_body:read(R, 0),
    ?assert(livery_body:ended(R1)),
    %% second read short-circuits without touching the mailbox
    ?assertEqual({done, R1}, livery_body:read(R1, 0)).

read_trailers_test() ->
    Ref = make_ref(),
    R = livery_body:new(Ref),
    Trailers = [{<<"x-checksum">>, <<"abc">>}],
    self() ! {livery_body, Ref, {trailers, Trailers}},
    {done, R1} = livery_body:read(R, 0),
    ?assert(livery_body:ended(R1)),
    ?assertEqual(Trailers, livery_body:trailers(R1)).

read_timeout_test() ->
    R = livery_body:new(make_ref()),
    ?assertMatch({error, timeout, _}, livery_body:read(R, 0)).

read_reset_test() ->
    Ref = make_ref(),
    R = livery_body:new(Ref),
    self() ! {livery_body, Ref, {reset, peer_gone}},
    {error, {client_reset, peer_gone}, R1} = livery_body:read(R, 0),
    %% subsequent reads stay in error state
    ?assertEqual({error, {client_reset, peer_gone}, R1},
                 livery_body:read(R1, 0)).

read_all_concats_chunks_test() ->
    Ref = make_ref(),
    R = livery_body:new(Ref),
    self() ! {livery_body, Ref, {data, <<"ab">>}},
    self() ! {livery_body, Ref, {data, <<"cd">>}},
    self() ! {livery_body, Ref, {data, <<"ef">>}},
    self() ! {livery_body, Ref, eof},
    {ok, Body, R1} = livery_body:read_all(R, 50),
    ?assertEqual(<<"abcdef">>, Body),
    ?assert(livery_body:ended(R1)).

read_all_propagates_reset_test() ->
    Ref = make_ref(),
    R = livery_body:new(Ref),
    self() ! {livery_body, Ref, {data, <<"abc">>}},
    self() ! {livery_body, Ref, {reset, gone}},
    ?assertMatch({error, {client_reset, gone}, _},
                 livery_body:read_all(R, 50)).

discard_drains_until_eof_test() ->
    Ref = make_ref(),
    R = livery_body:new(Ref),
    self() ! {livery_body, Ref, {data, <<"x">>}},
    self() ! {livery_body, Ref, {data, <<"y">>}},
    self() ! {livery_body, Ref, eof},
    {ok, R1} = livery_body:discard(R, 50),
    ?assert(livery_body:ended(R1)),
    %% mailbox drained
    ?assertMatch({done, _}, livery_body:read(R1, 0)).

signal_demand_no_source_is_ok_test() ->
    ?assertEqual(ok, livery_body:signal_demand(livery_body:new(), 4096)).

signal_demand_sends_message_test() ->
    Ref = make_ref(),
    R = livery_body:new(Ref, self()),
    ?assertEqual(self(), livery_body:source(R)),
    ok = livery_body:signal_demand(R, 1024),
    receive
        {livery_body_demand, Ref, 1024} -> ok
    after 100 ->
        ?assert(false)
    end.

%%====================================================================
%% Interleaved and large payload edge cases
%%====================================================================

interleaved_with_unrelated_messages_test() ->
    Ref = make_ref(),
    R = livery_body:new(Ref),
    self() ! {unrelated, 1},
    self() ! {livery_body, Ref, {data, <<"x">>}},
    self() ! {unrelated, 2},
    self() ! {livery_body, Ref, eof},
    {ok, Body, R1} = livery_body:read_all(R, 50),
    ?assertEqual(<<"x">>, Body),
    ?assert(livery_body:ended(R1)),
    %% unrelated messages remain in the mailbox
    receive {unrelated, 1} -> ok end,
    receive {unrelated, 2} -> ok end.

ignores_other_refs_test() ->
    Mine = make_ref(),
    Other = make_ref(),
    R = livery_body:new(Mine),
    self() ! {livery_body, Other, {data, <<"not mine">>}},
    self() ! {livery_body, Mine, {data, <<"mine">>}},
    self() ! {livery_body, Mine, eof},
    {ok, Body, _} = livery_body:read_all(R, 50),
    ?assertEqual(<<"mine">>, Body),
    %% leftover for Other is still in the mailbox
    receive {livery_body, Other, {data, <<"not mine">>}} -> ok end.

read_all_after_done_test() ->
    Ref = make_ref(),
    R = livery_body:new(Ref),
    self() ! {livery_body, Ref, eof},
    {ok, B1, R1} = livery_body:read_all(R, 50),
    ?assertEqual(<<>>, B1),
    {ok, B2, _} = livery_body:read_all(R1, 50),
    ?assertEqual(<<>>, B2).

large_chunked_body_test() ->
    Ref = make_ref(),
    R = livery_body:new(Ref),
    Big = binary:copy(<<"x">>, 4096),
    [self() ! {livery_body, Ref, {data, Big}} || _ <- lists:seq(1, 16)],
    self() ! {livery_body, Ref, eof},
    {ok, Body, _} = livery_body:read_all(R, 500),
    ?assertEqual(4096 * 16, byte_size(Body)).
