-module(livery_builtin_middleware_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% livery_request_id
%%====================================================================

request_id_generated_when_absent_test() ->
    Self = self(),
    Handler = fun(R) ->
        Self ! {req_id, livery_req:req_id(R)},
        livery_resp:text(200, <<"ok">>)
    end,
    Cap = livery_test_adapter:run(
        [{livery_request_id, undefined}], Handler, #{}
    ),
    Echoed = livery_test_adapter:header(<<"x-request-id">>, Cap),
    ?assert(is_binary(Echoed)),
    ?assertEqual(32, byte_size(Echoed)),
    receive
        {req_id, Id} -> ?assertEqual(Id, Echoed)
    after 100 ->
        ?assert(false)
    end.

request_id_honored_when_present_test() ->
    Handler = fun(_R) -> livery_resp:text(200, <<>>) end,
    Cap = livery_test_adapter:run(
        [{livery_request_id, undefined}],
        Handler,
        #{headers => [{<<"x-request-id">>, <<"client-supplied">>}]}
    ),
    ?assertEqual(
        <<"client-supplied">>,
        livery_test_adapter:header(<<"x-request-id">>, Cap)
    ).

%%====================================================================
%% livery_body_limit
%%====================================================================

body_limit_passes_when_under_cap_test() ->
    Handler = fun(_R) -> livery_resp:text(200, <<"ok">>) end,
    Cap = livery_test_adapter:run(
        [{livery_body_limit, #{max => 1024}}],
        Handler,
        #{body => {buffered, <<"hello">>}}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)).

body_limit_rejects_over_cap_test() ->
    Handler = fun(_R) -> error(must_not_be_called) end,
    Cap = livery_test_adapter:run(
        [{livery_body_limit, #{max => 4}}],
        Handler,
        #{body => {buffered, <<"hello world">>}}
    ),
    ?assertEqual(413, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"payload too large">>, livery_test_adapter:body(Cap)).

body_limit_passes_streaming_body_through_test() ->
    Handler = fun(_R) -> livery_resp:text(200, <<"streamed">>) end,
    Cap = livery_test_adapter:run(
        [{livery_body_limit, #{max => 1}}],
        Handler,
        #{body => {stream, fake}}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)).

%%====================================================================
%% livery_timeout
%%====================================================================

timeout_passes_fast_handler_test() ->
    Handler = fun(_R) -> livery_resp:text(200, <<"fast">>) end,
    Cap = livery_test_adapter:run(
        [{livery_timeout, #{after_ms => 1000}}], Handler, #{}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"fast">>, livery_test_adapter:body(Cap)).

timeout_returns_504_on_slow_handler_test() ->
    Handler = fun(_R) ->
        timer:sleep(200),
        livery_resp:text(200, <<"too late">>)
    end,
    Cap = livery_test_adapter:run(
        [{livery_timeout, #{after_ms => 30}}], Handler, #{}
    ),
    ?assertEqual(504, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"request timeout">>, livery_test_adapter:body(Cap)).

timeout_maps_crash_to_500_test() ->
    Handler = fun(_R) -> error(boom) end,
    Cap = livery_test_adapter:run(
        [{livery_timeout, #{after_ms => 1000}}], Handler, #{}
    ),
    ?assertEqual(500, livery_test_adapter:status(Cap)).

%%====================================================================
%% livery_access_log
%%====================================================================

access_log_emits_and_returns_response_test() ->
    %% Install a process handler that records log entries to our mailbox.
    Self = self(),
    HandlerId = test_handler,
    Primary = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    ok = logger:add_handler(
        HandlerId,
        ?MODULE,
        #{
            config => Self,
            level => all,
            formatter => {logger_formatter, #{}}
        }
    ),
    try
        Handler = fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        Cap = livery_test_adapter:run(
            [{livery_access_log, #{}}],
            Handler,
            #{method => <<"POST">>, path => <<"/foo">>}
        ),
        ?assertEqual(200, livery_test_adapter:status(Cap)),
        ?assertEqual(<<"ok">>, livery_test_adapter:body(Cap)),
        receive
            {log_event, Event} ->
                Msg = maps:get(msg, Event),
                ?assertMatch(
                    {report, #{
                        msg := "livery_access",
                        method := <<"POST">>,
                        path := <<"/foo">>,
                        status := 200
                    }},
                    Msg
                )
        after 200 ->
            ?assert(false)
        end
    after
        logger:remove_handler(HandlerId),
        logger:set_primary_config(level, maps:get(level, Primary))
    end.

%% logger handler callback used by access_log_emits_and_returns_response_test
log(Event, #{config := Pid}) ->
    Pid ! {log_event, Event},
    ok.

%%====================================================================
%% Composition: built-ins together
%%====================================================================

request_id_visible_to_downstream_middleware_test() ->
    Self = self(),
    Stack = [
        {livery_request_id, undefined},
        fun(R, Next) ->
            Self ! {seen_req_id, livery_req:req_id(R)},
            Next(R)
        end
    ],
    Cap = livery_test_adapter:run(
        Stack,
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        #{}
    ),
    Echoed = livery_test_adapter:header(<<"x-request-id">>, Cap),
    receive
        {seen_req_id, Id} -> ?assertEqual(Id, Echoed)
    after 100 ->
        ?assert(false)
    end.

body_limit_with_iolist_body_test() ->
    %% iolist size is byte size, not list length.
    Handler = fun(_R) -> error(must_not_be_called) end,
    Cap = livery_test_adapter:run(
        [{livery_body_limit, #{max => 3}}],
        Handler,
        #{body => {buffered, [<<"ab">>, [<<"cd">>], <<"ef">>]}}
    ),
    ?assertEqual(413, livery_test_adapter:status(Cap)).

body_limit_accepts_empty_body_test() ->
    Cap = livery_test_adapter:run(
        [{livery_body_limit, #{max => 0}}],
        fun(_R) -> livery_resp:text(200, <<>>) end,
        #{}
    ),
    %% empty (not buffered) bypasses the size check
    ?assertEqual(200, livery_test_adapter:status(Cap)).

request_id_in_access_log_test() ->
    Self = self(),
    HandlerId = test_handler_rid,
    Primary = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    ok = logger:add_handler(
        HandlerId,
        ?MODULE,
        #{
            config => Self,
            level => all,
            formatter => {logger_formatter, #{}}
        }
    ),
    try
        Stack = [
            {livery_request_id, undefined},
            {livery_access_log, #{}}
        ],
        _Cap = livery_test_adapter:run(
            Stack, fun(_R) -> livery_resp:text(200, <<>>) end, #{}
        ),
        receive
            {log_event, #{msg := {report, Report}}} ->
                ReqId = maps:get(request_id, Report),
                ?assert(is_binary(ReqId)),
                ?assertEqual(32, byte_size(ReqId))
        after 200 ->
            ?assert(false)
        end
    after
        logger:remove_handler(HandlerId),
        logger:set_primary_config(level, maps:get(level, Primary))
    end.
