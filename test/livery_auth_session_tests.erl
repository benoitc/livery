-module(livery_auth_session_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

-define(SECRET, <<"test-secret-please-change">>).

%%====================================================================
%% sign / verify
%%====================================================================

sign_verify_roundtrip_test() ->
    Data = #{<<"uid">> => 42, <<"role">> => <<"admin">>},
    Cookie = livery_auth_session:sign(Data, #{secret => ?SECRET}),
    ?assertEqual({ok, Data}, livery_auth_session:verify(Cookie, #{secret => ?SECRET})).

tampered_payload_is_rejected_test() ->
    %% Swap a valid payload onto another valid signature: both halves
    %% decode, but the HMAC no longer matches.
    C1 = livery_auth_session:sign(#{<<"uid">> => 1}, #{secret => ?SECRET}),
    C2 = livery_auth_session:sign(#{<<"uid">> => 2}, #{secret => ?SECRET}),
    [P1, _] = binary:split(C1, <<".">>),
    [_, Sig2] = binary:split(C2, <<".">>),
    Forged = <<P1/binary, ".", Sig2/binary>>,
    ?assertEqual(
        {error, bad_signature},
        livery_auth_session:verify(Forged, #{secret => ?SECRET})
    ).

wrong_secret_is_rejected_test() ->
    Cookie = livery_auth_session:sign(#{<<"uid">> => 1}, #{secret => ?SECRET}),
    ?assertEqual(
        {error, bad_signature},
        livery_auth_session:verify(Cookie, #{secret => <<"other">>})
    ).

malformed_cookie_is_rejected_test() ->
    ?assertEqual(
        {error, malformed},
        livery_auth_session:verify(<<"no-dot-here">>, #{secret => ?SECRET})
    ).

expired_cookie_is_rejected_test() ->
    Past = erlang:system_time(second) - 10,
    Cookie = livery_auth_session:sign(#{<<"exp">> => Past}, #{secret => ?SECRET}),
    ?assertEqual(
        {error, expired},
        livery_auth_session:verify(Cookie, #{secret => ?SECRET})
    ).

max_age_embeds_future_exp_test() ->
    Cookie = livery_auth_session:sign(
        #{<<"uid">> => 1},
        #{secret => ?SECRET, max_age => 3600}
    ),
    {ok, Map} = livery_auth_session:verify(Cookie, #{secret => ?SECRET}),
    ?assert(maps:is_key(<<"exp">>, Map)),
    ?assert(map_get(<<"exp">>, Map) > erlang:system_time(second)).

%%====================================================================
%% Set-Cookie builders
%%====================================================================

set_cookie_header_defaults_test() ->
    {<<"set-cookie">>, V} =
        livery_auth_session:set_cookie_header(<<"abc">>, #{}),
    ?assertEqual(<<"session=abc; Path=/; SameSite=Lax; Secure; HttpOnly">>, V).

set_cookie_header_with_attrs_test() ->
    {<<"set-cookie">>, V} = livery_auth_session:set_cookie_header(
        <<"abc">>, #{
            name => <<"sid">>,
            max_age => 60,
            secure => false,
            http_only => true,
            same_site => <<"Strict">>
        }
    ),
    ?assertEqual(
        <<"sid=abc; Path=/; Max-Age=60; SameSite=Strict; HttpOnly">>, V
    ).

clear_cookie_header_test() ->
    {<<"set-cookie">>, V} = livery_auth_session:clear_cookie_header(#{}),
    ?assertEqual(<<"session=; Path=/; Max-Age=0">>, V).

%%====================================================================
%% cookie extractor
%%====================================================================

cookie_extractor_finds_named_value_test() ->
    Req = req_with_cookie(<<"a=1; session=xyz; b=2">>),
    ?assertEqual(<<"xyz">>, livery_ext:cookie(<<"session">>, Req)),
    ?assertEqual(<<"1">>, livery_ext:cookie(<<"a">>, Req)),
    ?assertEqual(undefined, livery_ext:cookie(<<"missing">>, Req)).

cookie_extractor_no_header_test() ->
    Req = livery_req:new(#{method => <<"GET">>, path => <<"/">>}),
    ?assertEqual(undefined, livery_ext:cookie(<<"session">>, Req)).

%%====================================================================
%% Middleware
%%====================================================================

handler() ->
    fun(R) ->
        case livery_ext:session(R) of
            undefined -> livery_resp:text(200, <<"anon">>);
            #{<<"uid">> := Uid} -> livery_resp:text(200, integer_to_binary(Uid))
        end
    end.

valid_cookie_sets_session_meta_test() ->
    Cookie = livery_auth_session:sign(#{<<"uid">> => 7}, #{secret => ?SECRET}),
    Stack = [{livery_auth_session, #{secret => ?SECRET}}],
    Cap = livery_test_adapter:run(
        Stack,
        handler(),
        #{headers => [{<<"cookie">>, <<"session=", Cookie/binary>>}]}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"7">>, livery_test_adapter:body(Cap)).

missing_cookie_optional_passes_through_test() ->
    Stack = [{livery_auth_session, #{secret => ?SECRET}}],
    Cap = livery_test_adapter:run(Stack, handler(), #{}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"anon">>, livery_test_adapter:body(Cap)).

missing_cookie_required_rejected_test() ->
    Stack = [{livery_auth_session, #{secret => ?SECRET, required => true}}],
    Cap = livery_test_adapter:run(Stack, handler(), #{}),
    ?assertEqual(401, livery_test_adapter:status(Cap)).

invalid_cookie_rejected_test() ->
    Stack = [{livery_auth_session, #{secret => ?SECRET}}],
    Cap = livery_test_adapter:run(
        Stack,
        handler(),
        #{headers => [{<<"cookie">>, <<"session=garbage.sig">>}]}
    ),
    ?assertEqual(401, livery_test_adapter:status(Cap)).

custom_meta_key_test() ->
    Cookie = livery_auth_session:sign(#{<<"uid">> => 9}, #{secret => ?SECRET}),
    H = fun(R) ->
        #{<<"uid">> := Uid} = livery_req:meta(sess, R),
        livery_resp:text(200, integer_to_binary(Uid))
    end,
    Stack = [{livery_auth_session, #{secret => ?SECRET, meta_key => sess}}],
    Cap = livery_test_adapter:run(
        Stack,
        H,
        #{headers => [{<<"cookie">>, <<"session=", Cookie/binary>>}]}
    ),
    ?assertEqual(<<"9">>, livery_test_adapter:body(Cap)).

%%====================================================================
%% Helpers
%%====================================================================

req_with_cookie(Value) ->
    livery_req:new(#{
        method => <<"GET">>,
        path => <<"/">>,
        headers => [{<<"cookie">>, Value}]
    }).

%% RFC 7519 4.1.4 semantics for the session's `exp': expired at `exp'.
session_expires_at_exp_test() ->
    Secret = <<"s">>,
    Now = erlang:system_time(second),
    Expired = livery_auth_session:sign(#{<<"exp">> => Now}, #{secret => Secret}),
    Live = livery_auth_session:sign(#{<<"exp">> => Now + 60}, #{secret => Secret}),
    ?assertEqual({error, expired}, livery_auth_session:verify(Expired, #{secret => Secret})),
    ?assertMatch({ok, _}, livery_auth_session:verify(Live, #{secret => Secret})).

%%====================================================================
%% Purposes: a cookie signed for one use is refused for any other
%%====================================================================

purpose_roundtrip_test() ->
    Opts = #{secret => ?SECRET, purpose => <<"state">>},
    Cookie = livery_auth_session:sign(#{<<"s">> => 1}, Opts),
    ?assertEqual({ok, #{<<"s">> => 1}}, livery_auth_session:verify(Cookie, Opts)).

purposes_do_not_cross_test() ->
    Cookie = livery_auth_session:sign(#{<<"s">> => 1}, #{secret => ?SECRET, purpose => <<"a">>}),
    ?assertEqual(
        {error, bad_signature},
        livery_auth_session:verify(Cookie, #{secret => ?SECRET, purpose => <<"b">>})
    ),
    ?assertEqual({error, bad_signature}, livery_auth_session:verify(Cookie, #{secret => ?SECRET})).

purpose_cookie_is_not_a_session_test() ->
    Cookie = livery_auth_session:sign(#{<<"s">> => 1}, #{secret => ?SECRET, purpose => <<"a">>}),
    Stack = [{livery_auth_session, #{secret => ?SECRET, required => true}}],
    Cap = livery_test_adapter:run(
        Stack, handler(), #{headers => [{<<"cookie">>, <<"session=", Cookie/binary>>}]}
    ),
    ?assertEqual(401, livery_test_adapter:status(Cap)).

%%====================================================================
%% Server-side sessions: a store lets a session be ended early
%%====================================================================

-define(ISS, <<"https://id.example">>).

store_opts() ->
    #{secret => ?SECRET, max_age => 3600, store => livery_auth_session_ets}.

store_test_() ->
    {setup,
        fun() ->
            {ok, Apps} = application:ensure_all_started(livery),
            Apps
        end,
        fun(Apps) -> [application:stop(A) || A <- lists:reverse(Apps)] end, [
            {"create without a store is sign", fun create_without_store/0},
            {"create with a store needs max_age", fun create_needs_max_age/0},
            {"a recorded session passes", fun recorded_session_passes/0},
            {"a revoked session is refused and cleared", fun revoked_session_refused/0},
            {"revoke_user ends every session of the user", fun revoke_user_ends_all/0},
            {"a cookie without a session id is refused", fun cookie_without_sid_refused/0},
            {"end_session revokes the request's session", fun end_session_revokes/0},
            {"a full store refuses the session", fun full_store_refuses/0}
        ]}.

with_cookie(Value) ->
    #{headers => [{<<"cookie">>, <<"session=", Value/binary>>}]}.

run_with_store(Value) ->
    livery_test_adapter:run([{livery_auth_session, store_opts()}], handler(), with_cookie(Value)).

open(Sub) ->
    {ok, Value} = livery_auth_session:create(
        #{<<"uid">> => 1}, #{iss => ?ISS, sub => Sub}, store_opts()
    ),
    Value.

sid(Value) ->
    {ok, #{<<"livery_sid">> := Sid}} = livery_auth_session:verify(Value, store_opts()),
    Sid.

create_without_store() ->
    Opts = #{secret => ?SECRET},
    {ok, Value} = livery_auth_session:create(
        #{<<"uid">> => 1}, #{iss => ?ISS, sub => <<"a">>}, Opts
    ),
    ?assertEqual({ok, #{<<"uid">> => 1}}, livery_auth_session:verify(Value, Opts)).

create_needs_max_age() ->
    ?assertError(
        {missing_option, max_age},
        livery_auth_session:create(
            #{}, #{iss => ?ISS, sub => <<"a">>}, maps:remove(max_age, store_opts())
        )
    ).

recorded_session_passes() ->
    Cap = run_with_store(open(<<"alice">>)),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"1">>, livery_test_adapter:body(Cap)).

revoked_session_refused() ->
    Value = open(<<"alice">>),
    ok = livery_auth_session:revoke(sid(Value), store_opts()),
    Cap = run_with_store(Value),
    ?assertEqual(401, livery_test_adapter:status(Cap)),
    ?assertEqual(
        <<"session=; Path=/; Max-Age=0">>, livery_test_adapter:header(<<"set-cookie">>, Cap)
    ).

revoke_user_ends_all() ->
    A1 = open(<<"bob">>),
    A2 = open(<<"bob">>),
    Other = open(<<"carol">>),
    ok = livery_auth_session:revoke_user(?ISS, <<"bob">>, store_opts()),
    ?assertEqual(
        [401, 401, 200],
        [livery_test_adapter:status(run_with_store(V)) || V <- [A1, A2, Other]]
    ).

cookie_without_sid_refused() ->
    Old = livery_auth_session:sign(#{<<"uid">> => 1}, store_opts()),
    ?assertEqual(401, livery_test_adapter:status(run_with_store(Old))).

end_session_revokes() ->
    Value = open(<<"dave">>),
    Req = req_with_cookie(<<"session=", Value/binary>>),
    ok = livery_auth_session:end_session(Req, store_opts()),
    ?assertEqual(invalid, livery_auth_session_ets:check(undefined, sid(Value))),
    ?assertEqual(ok, livery_auth_session:end_session(Req, #{secret => ?SECRET})).

full_store_refuses() ->
    application:set_env(livery, session_max, 0),
    try
        ?assertEqual(
            {error, full},
            livery_auth_session:create(#{}, #{iss => ?ISS, sub => <<"e">>}, store_opts())
        )
    after
        application:unset_env(livery, session_max)
    end.

%% Without a store the middleware never looks for a session id.
no_store_unchanged_test() ->
    Cookie = livery_auth_session:sign(#{<<"uid">> => 3}, #{secret => ?SECRET}),
    Cap = livery_test_adapter:run(
        [{livery_auth_session, #{secret => ?SECRET}}], handler(), with_cookie(Cookie)
    ),
    ?assertEqual(<<"3">>, livery_test_adapter:body(Cap)).
