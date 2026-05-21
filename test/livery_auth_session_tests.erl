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
