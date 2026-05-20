-module(livery_auth_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, 1_700_000_000).

%%====================================================================
%% livery_auth:verify/2 — RS256
%%====================================================================

rs256_happy_path_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"rsa-1">>},
        #{<<"sub">> => <<"alice">>, <<"exp">> => ?NOW + 3600}),
    ?assertMatch({ok, #{<<"sub">> := <<"alice">>}},
                 livery_auth:verify(Token,
                     #{keys => [Jwk], now => ?NOW})).

rs256_bad_signature_test() ->
    {Key, _Jwk} = livery_auth_jwt:rsa_keypair(),
    {_OtherKey, OtherJwk} = livery_auth_jwt:rsa_keypair(<<"rsa-1">>),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"rsa-1">>},
        #{<<"sub">> => <<"alice">>, <<"exp">> => ?NOW + 3600}),
    %% Verify against a different key with the same kid.
    ?assertEqual({error, bad_signature},
                 livery_auth:verify(Token,
                     #{keys => [OtherJwk], now => ?NOW})).

%%====================================================================
%% livery_auth:verify/2 — ES256
%%====================================================================

es256_happy_path_test() ->
    {Key, Jwk} = livery_auth_jwt:ec_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"ec-1">>},
        #{<<"sub">> => <<"bob">>, <<"exp">> => ?NOW + 3600}),
    ?assertMatch({ok, #{<<"sub">> := <<"bob">>}},
                 livery_auth:verify(Token,
                     #{keys => [Jwk], now => ?NOW})).

%%====================================================================
%% Claim validation
%%====================================================================

expired_token_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"rsa-1">>},
        #{<<"sub">> => <<"alice">>, <<"exp">> => ?NOW - 1}),
    ?assertEqual({error, expired},
                 livery_auth:verify(Token, #{keys => [Jwk], now => ?NOW})).

leeway_allows_recent_expiry_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"rsa-1">>},
        #{<<"exp">> => ?NOW - 5}),
    ?assertMatch({ok, _},
                 livery_auth:verify(Token,
                     #{keys => [Jwk], now => ?NOW, leeway => 10})).

not_yet_valid_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"rsa-1">>},
        #{<<"nbf">> => ?NOW + 100, <<"exp">> => ?NOW + 3600}),
    ?assertEqual({error, not_yet_valid},
                 livery_auth:verify(Token, #{keys => [Jwk], now => ?NOW})).

issuer_mismatch_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"rsa-1">>},
        #{<<"iss">> => <<"https://evil">>, <<"exp">> => ?NOW + 3600}),
    ?assertMatch({error, {issuer_mismatch, _}},
                 livery_auth:verify(Token,
                     #{keys => [Jwk], now => ?NOW,
                       issuer => <<"https://good">>})).

audience_match_in_list_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"rsa-1">>},
        #{<<"aud">> => [<<"other">>, <<"my-api">>], <<"exp">> => ?NOW + 3600}),
    ?assertMatch({ok, _},
                 livery_auth:verify(Token,
                     #{keys => [Jwk], now => ?NOW, audience => <<"my-api">>})).

audience_mismatch_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"rsa-1">>},
        #{<<"aud">> => <<"someone-else">>, <<"exp">> => ?NOW + 3600}),
    ?assertEqual({error, audience_mismatch},
                 livery_auth:verify(Token,
                     #{keys => [Jwk], now => ?NOW, audience => <<"my-api">>})).

%%====================================================================
%% Key selection
%%====================================================================

picks_key_by_kid_test() ->
    {Key1, Jwk1} = livery_auth_jwt:rsa_keypair(<<"k1">>),
    {_Key2, Jwk2} = livery_auth_jwt:rsa_keypair(<<"k2">>),
    Token = livery_auth_jwt:mint(Key1, #{<<"kid">> => <<"k1">>},
        #{<<"exp">> => ?NOW + 3600}),
    ?assertMatch({ok, _},
                 livery_auth:verify(Token,
                     #{keys => [Jwk2, Jwk1], now => ?NOW})).

no_matching_key_test() ->
    {Key, _Jwk} = livery_auth_jwt:rsa_keypair(<<"k1">>),
    {_K2, Jwk2} = livery_auth_jwt:rsa_keypair(<<"k2">>),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"k1">>},
        #{<<"exp">> => ?NOW + 3600}),
    ?assertEqual({error, no_matching_key},
                 livery_auth:verify(Token, #{keys => [Jwk2], now => ?NOW})).

%%====================================================================
%% Malformed input
%%====================================================================

malformed_token_test() ->
    ?assertEqual({error, malformed},
                 livery_auth:verify(<<"not-a-jwt">>, #{keys => []})).

unsupported_alg_test() ->
    %% alg=none style token (two segments + empty sig won't even split
    %% to 3 cleanly); craft an HS256 header which we don't support.
    {_Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    H = base64:encode(iolist_to_binary(json:encode(#{<<"alg">> => <<"HS256">>})),
                      #{mode => urlsafe, padding => false}),
    P = base64:encode(iolist_to_binary(json:encode(#{<<"exp">> => ?NOW + 1})),
                      #{mode => urlsafe, padding => false}),
    Token = <<H/binary, ".", P/binary, ".", "c2ln">>,
    ?assertEqual({error, {unsupported_alg, <<"HS256">>}},
                 livery_auth:verify(Token, #{keys => [Jwk], now => ?NOW})).

%%====================================================================
%% livery_auth_bearer middleware + livery_ext:user/1
%%====================================================================

bearer_accepts_valid_token_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"rsa-1">>},
        #{<<"sub">> => <<"alice">>, <<"exp">> => future()}),
    Stack = [{livery_auth_bearer, #{keys => [Jwk]}}],
    Handler = fun(R) ->
        #{<<"sub">> := Sub} = livery_ext:user(R),
        livery_resp:text(200, Sub)
    end,
    Cap = livery_test_adapter:run(Stack, Handler,
        #{headers => [{<<"authorization">>, <<"Bearer ", Token/binary>>}]}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"alice">>, livery_test_adapter:body(Cap)).

bearer_rejects_missing_token_test() ->
    Stack = [{livery_auth_bearer, #{keys => []}}],
    Cap = livery_test_adapter:run(Stack,
        fun(_R) -> error(must_not_be_called) end, #{}),
    ?assertEqual(401, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"Bearer">>,
                 livery_test_adapter:header(<<"www-authenticate">>, Cap)).

bearer_rejects_expired_token_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"rsa-1">>},
        #{<<"exp">> => 1}),
    Stack = [{livery_auth_bearer, #{keys => [Jwk]}}],
    Cap = livery_test_adapter:run(Stack,
        fun(_R) -> error(must_not_be_called) end,
        #{headers => [{<<"authorization">>, <<"Bearer ", Token/binary>>}]}),
    ?assertEqual(401, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"token expired">>, livery_test_adapter:body(Cap)).

bearer_optional_allows_missing_test() ->
    Stack = [{livery_auth_bearer, #{keys => [], required => false}}],
    Handler = fun(R) ->
        case livery_ext:user(R) of
            undefined -> livery_resp:text(200, <<"anon">>);
            _         -> livery_resp:text(200, <<"auth">>)
        end
    end,
    Cap = livery_test_adapter:run(Stack, Handler, #{}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"anon">>, livery_test_adapter:body(Cap)).

bearer_optional_still_rejects_bad_token_test() ->
    {_K1, Jwk} = livery_auth_jwt:rsa_keypair(<<"k1">>),
    {Key2, _J2} = livery_auth_jwt:rsa_keypair(<<"k1">>),
    Token = livery_auth_jwt:mint(Key2, #{<<"kid">> => <<"k1">>},
        #{<<"exp">> => future()}),
    Stack = [{livery_auth_bearer, #{keys => [Jwk], required => false}}],
    Cap = livery_test_adapter:run(Stack,
        fun(_R) -> error(must_not_be_called) end,
        #{headers => [{<<"authorization">>, <<"Bearer ", Token/binary>>}]}),
    ?assertEqual(401, livery_test_adapter:status(Cap)).

%%====================================================================
%% Helpers
%%====================================================================

future() ->
    os:system_time(second) + 3600.
