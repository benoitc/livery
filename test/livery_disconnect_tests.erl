-module(livery_disconnect_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% livery_disconnect helper
%%====================================================================

fire_signals_worker_and_runs_callbacks_test() ->
    Self = self(),
    Ref = make_ref(),
    ok = livery_disconnect:fire(Self, Ref, gone, [
        fun() -> Self ! cb_a end,
        fun() -> Self ! cb_b end
    ]),
    receive
        {livery_disconnect, R, gone} -> ?assertEqual(Ref, R)
    after 500 -> ?assert(false)
    end,
    ?assert(got(cb_a)),
    ?assert(got(cb_b)).

fire_once_fires_only_on_first_test() ->
    Self = self(),
    Ref = make_ref(),
    %% Not yet fired -> fires, returns true.
    ?assertEqual(true, livery_disconnect:fire_once(false, Self, Ref, r1, [])),
    receive
        {livery_disconnect, Ref, r1} -> ok
    after 500 -> ?assert(false)
    end,
    %% Already fired -> no-op, returns true.
    ?assertEqual(true, livery_disconnect:fire_once(true, Self, Ref, r2, [])),
    ?assertEqual(false, got({livery_disconnect, Ref, r2})).

register_before_fire_accumulates_test() ->
    Fun = fun() -> ok end,
    ?assertEqual([Fun], livery_disconnect:register(false, Fun, [])).

register_after_fire_spawns_immediately_test() ->
    Self = self(),
    Cbs = [fun() -> already end],
    %% Fired = true: run now, leave the list unchanged.
    ?assertEqual(Cbs, livery_disconnect:register(true, fun() -> Self ! ran_now end, Cbs)),
    ?assert(got(ran_now)).

%%====================================================================
%% livery_req:on_disconnect/2
%%====================================================================

on_disconnect_messages_notifier_test() ->
    Self = self(),
    Ref = make_ref(),
    Req = livery_req:new(#{notifier_pid => Self, disc_ref => Ref}),
    Fun = fun() -> ok end,
    ok = livery_req:on_disconnect(Req, Fun),
    receive
        {livery_on_disconnect, R, F} ->
            ?assertEqual(Ref, R),
            ?assertEqual(Fun, F)
    after 500 -> ?assert(false)
    end.

on_disconnect_noop_without_notifier_test() ->
    Req = livery_req:new(#{}),
    ?assertEqual(ok, livery_req:on_disconnect(Req, fun() -> self() ! nope end)),
    ?assertEqual(false, got(nope)).

disconnect_tag_test() ->
    ?assertEqual(livery_disconnect, livery_req:disconnect_tag()).

%%====================================================================
%% Streaming producer error short-circuits the terminal close
%%====================================================================

chunked_producer_error_skips_close_test() ->
    Cap = livery_test_adapter:run(
        [],
        fun(_R) ->
            livery_resp:stream(200, [], fun(Emit) ->
                Emit(<<"one">>),
                {error, closed}
            end)
        end,
        #{}
    ),
    ?assertEqual(<<"one">>, livery_test_adapter:body(Cap)),
    ?assertNot(livery_test_adapter:end_stream(Cap)).

chunked_producer_ok_closes_test() ->
    Cap = livery_test_adapter:run(
        [],
        fun(_R) ->
            livery_resp:stream(200, [], fun(Emit) ->
                Emit(<<"one">>),
                ok
            end)
        end,
        #{}
    ),
    ?assert(livery_test_adapter:end_stream(Cap)).

ndjson_producer_error_skips_close_test() ->
    Cap = livery_test_adapter:run(
        [],
        fun(_R) ->
            livery_resp:ndjson(200, fun(Emit) ->
                Emit(#{<<"n">> => 1}),
                {error, closed}
            end)
        end,
        #{}
    ),
    ?assertEqual(<<"{\"n\":1}\n">>, livery_test_adapter:body(Cap)),
    ?assertNot(livery_test_adapter:end_stream(Cap)).

ndjson_producer_ok_closes_test() ->
    Cap = livery_test_adapter:run(
        [],
        fun(_R) ->
            livery_resp:ndjson(200, fun(Emit) ->
                Emit(#{<<"n">> => 1}),
                ok
            end)
        end,
        #{}
    ),
    ?assert(livery_test_adapter:end_stream(Cap)).

%%====================================================================
%% Helpers
%%====================================================================

got(Msg) ->
    receive
        Msg -> true
    after 200 -> false
    end.
