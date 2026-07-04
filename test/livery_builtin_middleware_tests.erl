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

access_log_sanitizes_control_bytes_test() ->
    Self = self(),
    HandlerId = test_handler_sanitize,
    Primary = logger:get_primary_config(),
    ok = logger:set_primary_config(level, all),
    ok = logger:add_handler(
        HandlerId,
        ?MODULE,
        #{config => Self, level => all, formatter => {logger_formatter, #{}}}
    ),
    try
        Handler = fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        _ = livery_test_adapter:run(
            [{livery_access_log, #{}}],
            Handler,
            #{method => <<"GET">>, path => <<"/a\r\nb\tc">>}
        ),
        receive
            {log_event, Event} ->
                {report, Report} = maps:get(msg, Event),
                %% CR/LF/TAB replaced with spaces so no extra log line.
                ?assertEqual(<<"/a  b c">>, maps:get(path, Report))
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

%%====================================================================
%% livery_cors
%%====================================================================

cors_preflight_returns_204_and_skips_handler_test() ->
    Cap = livery_test_adapter:run(
        [{livery_cors, #{origins => [<<"http://app.test">>]}}],
        fun(_R) -> error(must_not_be_called) end,
        #{
            method => <<"OPTIONS">>,
            headers => [
                {<<"origin">>, <<"http://app.test">>},
                {<<"access-control-request-method">>, <<"POST">>}
            ]
        }
    ),
    ?assertEqual(204, livery_test_adapter:status(Cap)),
    ?assertEqual(
        <<"http://app.test">>,
        livery_test_adapter:header(<<"access-control-allow-origin">>, Cap)
    ),
    Methods = livery_test_adapter:header(<<"access-control-allow-methods">>, Cap),
    ?assert(is_binary(Methods)),
    %% QUERY is part of the default allow-methods set.
    ?assertNotEqual(nomatch, binary:match(Methods, <<"QUERY">>)).

cors_simple_allowed_origin_echoes_and_varies_test() ->
    Cap = run_cors(
        #{origins => [<<"http://app.test">>]},
        #{headers => [{<<"origin">>, <<"http://app.test">>}]}
    ),
    ?assertEqual(
        <<"http://app.test">>,
        livery_test_adapter:header(<<"access-control-allow-origin">>, Cap)
    ),
    ?assert(has_vary(<<"origin">>, Cap)).

cors_fun_origin_allowed_test() ->
    Pred = fun(Origin) -> Origin =:= <<"http://ok.test">> end,
    Cap = run_cors(
        #{origins => Pred},
        #{headers => [{<<"origin">>, <<"http://ok.test">>}]}
    ),
    ?assertEqual(
        <<"http://ok.test">>,
        livery_test_adapter:header(<<"access-control-allow-origin">>, Cap)
    ),
    ?assert(has_vary(<<"origin">>, Cap)).

cors_wildcard_no_credentials_test() ->
    Cap = run_cors(#{}, #{headers => [{<<"origin">>, <<"http://any.test">>}]}),
    ?assertEqual(
        <<"*">>,
        livery_test_adapter:header(<<"access-control-allow-origin">>, Cap)
    ),
    ?assertEqual([], vary_tokens(Cap)).

cors_wildcard_with_credentials_echoes_origin_test() ->
    Cap = run_cors(
        #{credentials => true},
        #{headers => [{<<"origin">>, <<"http://any.test">>}]}
    ),
    ?assertEqual(
        <<"http://any.test">>,
        livery_test_adapter:header(<<"access-control-allow-origin">>, Cap)
    ),
    ?assertEqual(
        <<"true">>,
        livery_test_adapter:header(<<"access-control-allow-credentials">>, Cap)
    ),
    ?assert(has_vary(<<"origin">>, Cap)).

cors_disallowed_origin_no_acao_but_varies_test() ->
    Cap = run_cors(
        #{origins => [<<"http://allowed.test">>]},
        #{headers => [{<<"origin">>, <<"http://evil.test">>}]}
    ),
    ?assertEqual(
        undefined,
        livery_test_adapter:header(<<"access-control-allow-origin">>, Cap)
    ),
    ?assert(has_vary(<<"origin">>, Cap)).

cors_no_origin_wildcard_byte_identical_test() ->
    Cap = run_cors(#{}, #{}),
    ?assertEqual(
        undefined,
        livery_test_adapter:header(<<"access-control-allow-origin">>, Cap)
    ),
    ?assertEqual([], vary_tokens(Cap)).

cors_no_origin_dependent_config_adds_vary_test() ->
    Cap = run_cors(#{origins => [<<"http://app.test">>]}, #{}),
    ?assertEqual(
        undefined,
        livery_test_adapter:header(<<"access-control-allow-origin">>, Cap)
    ),
    ?assert(has_vary(<<"origin">>, Cap)).

cors_mirror_preflight_echoes_and_varies_acrh_test() ->
    Cap = livery_test_adapter:run(
        [{livery_cors, #{origins => [<<"http://app.test">>]}}],
        fun(_R) -> error(must_not_be_called) end,
        #{
            method => <<"OPTIONS">>,
            headers => [
                {<<"origin">>, <<"http://app.test">>},
                {<<"access-control-request-method">>, <<"POST">>},
                {<<"access-control-request-headers">>, <<"x-custom, authorization">>}
            ]
        }
    ),
    ?assertEqual(
        <<"x-custom, authorization">>,
        livery_test_adapter:header(<<"access-control-allow-headers">>, Cap)
    ),
    ?assert(has_vary(<<"origin">>, Cap)),
    ?assert(has_vary(<<"access-control-request-headers">>, Cap)).

cors_expose_headers_on_simple_response_test() ->
    Cap = run_cors(
        #{expose => [<<"x-total-count">>, <<"x-page">>]},
        #{headers => [{<<"origin">>, <<"http://any.test">>}]}
    ),
    ?assertEqual(
        <<"x-total-count, x-page">>,
        livery_test_adapter:header(<<"access-control-expose-headers">>, Cap)
    ).

cors_does_not_duplicate_existing_vary_test() ->
    Handler = fun(_R) ->
        livery_resp:with_header(
            <<"vary">>, <<"Origin">>, livery_resp:text(200, <<"ok">>)
        )
    end,
    Cap = livery_test_adapter:run(
        [{livery_cors, #{origins => [<<"http://app.test">>]}}],
        Handler,
        #{headers => [{<<"origin">>, <<"http://app.test">>}]}
    ),
    Varys = [V || {<<"vary">>, V} <- livery_test_adapter:headers(Cap)],
    ?assertEqual(1, length(Varys)),
    ?assert(has_vary(<<"origin">>, Cap)).

%%====================================================================
%% livery_security_headers
%%====================================================================

security_defaults_test() ->
    Cap = run_sec(#{}, #{}),
    ?assertEqual(
        <<"nosniff">>,
        livery_test_adapter:header(<<"x-content-type-options">>, Cap)
    ),
    ?assertEqual(
        <<"DENY">>,
        livery_test_adapter:header(<<"x-frame-options">>, Cap)
    ),
    ?assertEqual(
        <<"no-referrer">>,
        livery_test_adapter:header(<<"referrer-policy">>, Cap)
    ).

security_hsts_present_on_https_test() ->
    Cap = run_sec(#{}, #{scheme => <<"https">>}),
    ?assertEqual(
        <<"max-age=31536000; includeSubDomains">>,
        livery_test_adapter:header(<<"strict-transport-security">>, Cap)
    ).

security_hsts_absent_on_http_test() ->
    Cap = run_sec(#{}, #{}),
    ?assertEqual(
        undefined,
        livery_test_adapter:header(<<"strict-transport-security">>, Cap)
    ).

security_preserves_handler_header_test() ->
    Handler = fun(_R) ->
        livery_resp:with_header(
            <<"x-frame-options">>, <<"SAMEORIGIN">>, livery_resp:text(200, <<"ok">>)
        )
    end,
    Cap = livery_test_adapter:run(
        [{livery_security_headers, #{}}], Handler, #{}
    ),
    ?assertEqual(
        <<"SAMEORIGIN">>,
        livery_test_adapter:header(<<"x-frame-options">>, Cap)
    ).

security_csp_present_when_configured_test() ->
    Cap = run_sec(#{csp => <<"default-src 'self'">>}, #{}),
    ?assertEqual(
        <<"default-src 'self'">>,
        livery_test_adapter:header(<<"content-security-policy">>, Cap)
    ).

security_csp_absent_by_default_test() ->
    Cap = run_sec(#{}, #{}),
    ?assertEqual(
        undefined,
        livery_test_adapter:header(<<"content-security-policy">>, Cap)
    ).

security_false_disables_header_test() ->
    Cap = run_sec(
        #{frame_options => false, content_type_options => false}, #{}
    ),
    ?assertEqual(
        undefined,
        livery_test_adapter:header(<<"x-frame-options">>, Cap)
    ),
    ?assertEqual(
        undefined,
        livery_test_adapter:header(<<"x-content-type-options">>, Cap)
    ).

cors_security_request_id_compose_test() ->
    Stack = [
        {livery_request_id, undefined},
        {livery_cors, #{origins => [<<"http://app.test">>]}},
        {livery_security_headers, #{}}
    ],
    Cap = livery_test_adapter:run(
        Stack,
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        #{
            scheme => <<"https">>,
            headers => [{<<"origin">>, <<"http://app.test">>}]
        }
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assert(is_binary(livery_test_adapter:header(<<"x-request-id">>, Cap))),
    ?assertEqual(
        <<"http://app.test">>,
        livery_test_adapter:header(<<"access-control-allow-origin">>, Cap)
    ),
    ?assertEqual(
        <<"nosniff">>,
        livery_test_adapter:header(<<"x-content-type-options">>, Cap)
    ),
    ?assert(has_vary(<<"origin">>, Cap)).

%%====================================================================
%% livery_concurrency
%%====================================================================

concurrency_under_limit_test() ->
    Cap = livery_test_adapter:run(
        [{livery_concurrency, livery_concurrency:limiter(5)}],
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        #{}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)).

concurrency_sheds_over_limit_test() ->
    Cap = livery_test_adapter:run(
        [{livery_concurrency, livery_concurrency:limiter(0)}],
        fun(_R) -> error(must_not_be_called) end,
        #{}
    ),
    ?assertEqual(503, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"service unavailable">>, livery_test_adapter:body(Cap)).

concurrency_retry_after_test() ->
    Cap = livery_test_adapter:run(
        [{livery_concurrency, livery_concurrency:limiter(0, #{retry_after => 30})}],
        fun(_R) -> error(must_not_be_called) end,
        #{}
    ),
    ?assertEqual(503, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"30">>, livery_test_adapter:header(<<"retry-after">>, Cap)).

concurrency_custom_status_test() ->
    Opts = #{status => 429, body => <<"slow down">>},
    Cap = livery_test_adapter:run(
        [{livery_concurrency, livery_concurrency:limiter(0, Opts)}],
        fun(_R) -> error(must_not_be_called) end,
        #{}
    ),
    ?assertEqual(429, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"slow down">>, livery_test_adapter:body(Cap)).

concurrency_holds_and_releases_test() ->
    %% Shared limiter (one atomics ref) across all requests.
    Stack = [{livery_concurrency, livery_concurrency:limiter(2)}],
    Self = self(),
    Blocking = fun(_R) ->
        %% The slot is acquired before the handler runs, so by here it is
        %% held; signal readiness, then block until released.
        Self ! {entered, self()},
        receive
            finish -> ok
        end,
        livery_resp:text(200, <<"ok">>)
    end,
    Runners = [
        spawn(fun() ->
            Cap = livery_test_adapter:run(Stack, Blocking, #{}),
            Self ! {done, self(), livery_test_adapter:status(Cap)}
        end)
     || _ <- lists:seq(1, 2)
    ],
    %% Wait until BOTH slots are provably occupied before the 3rd request.
    Entered = [
        receive
            {entered, P} -> P
        after 2000 -> error(handler_did_not_enter)
        end
     || _ <- lists:seq(1, 2)
    ],
    %% Third request is shed before its handler runs (no block).
    Cap3 = livery_test_adapter:run(
        Stack, fun(_R) -> error(must_not_be_called) end, #{}
    ),
    ?assertEqual(503, livery_test_adapter:status(Cap3)),
    %% Release the held handlers; both complete with 200.
    [P ! finish || P <- Entered],
    [
        receive
            {done, _, S} -> ?assertEqual(200, S)
        after 2000 -> error(runner_did_not_finish)
        end
     || _ <- Runners
    ],
    %% Slots returned: a fresh request is admitted.
    Cap4 = livery_test_adapter:run(
        Stack, fun(_R) -> livery_resp:text(200, <<"ok">>) end, #{}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap4)).

%%====================================================================
%% livery_etag
%%====================================================================

etag_auto_added_on_full_get_test() ->
    Cap = run_get([{livery_etag, #{}}], json_handler(), []),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    E = livery_test_adapter:header(<<"etag">>, Cap),
    ?assertMatch(<<$", _/binary>>, E).

etag_absent_on_chunked_test() ->
    Producer = fun(Emit) ->
        Emit(<<"x">>),
        ok
    end,
    Cap = run_get(
        [{livery_etag, #{}}],
        fun(_R) -> livery_resp:stream(200, [], Producer) end,
        []
    ),
    ?assertEqual(undefined, livery_test_adapter:header(<<"etag">>, Cap)).

etag_absent_on_post_test() ->
    Cap = livery_test_adapter:run(
        [{livery_etag, #{}}], json_handler(), #{method => <<"POST">>}
    ),
    ?assertEqual(undefined, livery_test_adapter:header(<<"etag">>, Cap)).

etag_304_on_match_test() ->
    First = run_get([{livery_etag, #{}}], json_handler(), []),
    E = livery_test_adapter:header(<<"etag">>, First),
    Cap = run_get([{livery_etag, #{}}], json_handler(), [{<<"if-none-match">>, E}]),
    ?assertEqual(304, livery_test_adapter:status(Cap)),
    ?assertEqual(<<>>, livery_test_adapter:body(Cap)),
    ?assertEqual(E, livery_test_adapter:header(<<"etag">>, Cap)),
    ?assertEqual(undefined, livery_test_adapter:header(<<"content-type">>, Cap)).

etag_304_on_star_test() ->
    Cap = run_get(
        [{livery_etag, #{}}], json_handler(), [{<<"if-none-match">>, <<"*">>}]
    ),
    ?assertEqual(304, livery_test_adapter:status(Cap)).

etag_200_on_nomatch_test() ->
    Cap = run_get(
        [{livery_etag, #{}}], json_handler(), [{<<"if-none-match">>, <<"\"other\"">>}]
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"{\"a\":1}">>, livery_test_adapter:body(Cap)),
    ?assert(is_binary(livery_test_adapter:header(<<"etag">>, Cap))).

etag_handler_set_preserved_test() ->
    H = fun(_R) -> livery_resp:with_etag(<<"v1">>, livery_resp:json(200, <<"{}">>)) end,
    Cap = run_get([{livery_etag, #{}}], H, []),
    ?assertEqual(<<"\"v1\"">>, livery_test_adapter:header(<<"etag">>, Cap)),
    Cap2 = run_get([{livery_etag, #{}}], H, [{<<"if-none-match">>, <<"\"v1\"">>}]),
    ?assertEqual(304, livery_test_adapter:status(Cap2)).

etag_handler_set_on_chunked_304_test() ->
    %% Conditional handling is NOT gated on {full, _}.
    Producer = fun(Emit) ->
        Emit(<<"data">>),
        ok
    end,
    H = fun(_R) ->
        livery_resp:with_etag(<<"c1">>, livery_resp:stream(200, [], Producer))
    end,
    Cap = run_get([{livery_etag, #{}}], H, [{<<"if-none-match">>, <<"\"c1\"">>}]),
    ?assertEqual(304, livery_test_adapter:status(Cap)),
    ?assertEqual(<<>>, livery_test_adapter:body(Cap)).

etag_weak_output_test() ->
    Cap = run_get([{livery_etag, #{weak => true}}], json_handler(), []),
    E = livery_test_adapter:header(<<"etag">>, Cap),
    ?assertMatch(<<"W/\"", _/binary>>, E),
    Cap2 = run_get(
        [{livery_etag, #{weak => true}}], json_handler(), [{<<"if-none-match">>, E}]
    ),
    ?assertEqual(304, livery_test_adapter:status(Cap2)).

etag_weak_comparison_test() ->
    H = fun(_R) -> livery_resp:with_etag(<<"v1">>, livery_resp:json(200, <<"{}">>)) end,
    Cap = run_get([{livery_etag, #{}}], H, [{<<"if-none-match">>, <<"W/\"v1\"">>}]),
    ?assertEqual(304, livery_test_adapter:status(Cap)).

etag_multiple_inm_headers_test() ->
    H = fun(_R) -> livery_resp:with_etag(<<"v1">>, livery_resp:json(200, <<"{}">>)) end,
    Cap = run_get([{livery_etag, #{}}], H, [
        {<<"if-none-match">>, <<"\"nope\"">>},
        {<<"if-none-match">>, <<"\"v1\"">>}
    ]),
    ?assertEqual(304, livery_test_adapter:status(Cap)).

etag_auto_off_test() ->
    Cap = run_get([{livery_etag, #{auto => false}}], json_handler(), []),
    ?assertEqual(undefined, livery_test_adapter:header(<<"etag">>, Cap)).

etag_cache_control_survives_304_test() ->
    H = fun(_R) ->
        R = livery_resp:with_cache_control(
            [public, {max_age, 60}], livery_resp:json(200, <<"{}">>)
        ),
        livery_resp:with_etag(<<"v1">>, R)
    end,
    Cap = run_get([{livery_etag, #{}}], H, [{<<"if-none-match">>, <<"\"v1\"">>}]),
    ?assertEqual(304, livery_test_adapter:status(Cap)),
    ?assertEqual(
        <<"public, max-age=60">>,
        livery_test_adapter:header(<<"cache-control">>, Cap)
    ).

with_etag_quoting_test() ->
    ?assertEqual(<<"\"abc\"">>, resp_etag(livery_resp:with_etag(<<"abc">>, base_resp()))),
    ?assertEqual(
        <<"\"abc\"">>, resp_etag(livery_resp:with_etag(<<"\"abc\"">>, base_resp()))
    ),
    ?assertEqual(
        <<"W/\"abc\"">>, resp_etag(livery_resp:with_etag(<<"W/\"abc\"">>, base_resp()))
    ).

with_cache_control_format_test() ->
    R1 = livery_resp:with_cache_control([public, {max_age, 60}, immutable], base_resp()),
    ?assertEqual(<<"public, max-age=60, immutable">>, resp_cc(R1)),
    R2 = livery_resp:with_cache_control(<<"no-store">>, base_resp()),
    ?assertEqual(<<"no-store">>, resp_cc(R2)).

%%====================================================================
%% Helpers
%%====================================================================

run_get(Stack, Handler, ReqHeaders) ->
    livery_test_adapter:run(
        Stack, Handler, #{method => <<"GET">>, headers => ReqHeaders}
    ).

json_handler() ->
    fun(_R) -> livery_resp:json(200, <<"{\"a\":1}">>) end.

base_resp() ->
    livery_resp:json(200, <<"{}">>).

resp_etag(Resp) ->
    resp_header(<<"etag">>, Resp).

resp_cc(Resp) ->
    resp_header(<<"cache-control">>, Resp).

resp_header(Name, Resp) ->
    case lists:keyfind(Name, 1, livery_resp:headers(Resp)) of
        {_, V} -> V;
        false -> undefined
    end.

run_cors(Cfg, Spec) ->
    livery_test_adapter:run(
        [{livery_cors, Cfg}],
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        Spec
    ).

run_sec(Cfg, Spec) ->
    livery_test_adapter:run(
        [{livery_security_headers, Cfg}],
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        Spec
    ).

vary_tokens(Cap) ->
    Values = [V || {<<"vary">>, V} <- livery_test_adapter:headers(Cap)],
    lists:flatmap(
        fun(V) ->
            [normalize_token(T) || T <- binary:split(V, <<",">>, [global])]
        end,
        Values
    ).

has_vary(Token, Cap) ->
    lists:member(normalize_token(Token), vary_tokens(Cap)).

normalize_token(Token) ->
    iolist_to_binary(string:trim(string:lowercase(Token))).
