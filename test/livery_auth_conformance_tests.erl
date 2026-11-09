%% @doc JOSE, JWT and RFC 6750 conformance of livery_auth and the bearer
%% middleware: every algorithm, key selection, `crit', NumericDate,
%% `typ', the RFC 9068 profile, scopes and the challenge header.
-module(livery_auth_conformance_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, 1_700_000_000).
-define(ALGS, [
    <<"RS256">>,
    <<"RS384">>,
    <<"RS512">>,
    <<"PS256">>,
    <<"PS384">>,
    <<"PS512">>,
    <<"ES256">>,
    <<"ES384">>,
    <<"ES512">>,
    <<"Ed25519">>,
    <<"Ed448">>
]).

claims() -> #{<<"sub">> => <<"alice">>, <<"exp">> => ?NOW + 60}.

verify(Token, Keys) -> verify(Token, Keys, #{}).

verify(Token, Keys, Opts) -> livery_auth:verify(Token, Opts#{keys => Keys, now => ?NOW}).

%%====================================================================
%% Algorithms (RFC 7518, RFC 9864)
%%====================================================================

every_algorithm_round_trips_test_() ->
    [
        {Alg, fun() ->
            {Key, Jwk} = livery_auth_jwt:keypair(Alg, <<"k">>),
            Token = livery_auth_jwt:mint(Key, #{<<"kid">> => <<"k">>}, claims()),
            ?assertMatch({ok, #{<<"sub">> := <<"alice">>}}, verify(Token, [Jwk]))
        end}
     || Alg <- ?ALGS
    ].

%% The deprecated `EdDSA' name still verifies, with the curve from the key.
eddsa_name_accepted_test() ->
    {{_, Priv}, Jwk} = livery_auth_jwt:keypair(<<"Ed25519">>, <<"k">>),
    Token = livery_auth_jwt:mint({<<"EdDSA">>, Priv}, #{}, claims()),
    ?assertMatch({ok, _}, verify(Token, [maps:remove(<<"alg">>, Jwk)])),
    ?assertMatch({ok, _}, verify(Token, [Jwk])).

none_and_hmac_refused_test() ->
    {_Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    [
        ?assertEqual({error, {unsupported_alg, Alg}}, verify(unsigned(Alg), [Jwk]))
     || Alg <- [<<"none">>, <<"HS256">>]
    ].

algorithms_option_limits_test() ->
    {Key, Jwk} = livery_auth_jwt:keypair(<<"PS256">>, <<"k">>),
    Token = livery_auth_jwt:mint(Key, #{}, claims()),
    ?assertEqual(
        {error, {unsupported_alg, <<"PS256">>}},
        verify(Token, [Jwk], #{algorithms => [<<"RS256">>]})
    ).

%%====================================================================
%% Key selection
%%====================================================================

key_with_other_alg_not_used_test() ->
    {Key, Jwk} = livery_auth_jwt:keypair(<<"RS256">>, <<"k">>),
    Token = livery_auth_jwt:mint(Key, #{}, claims()),
    ?assertEqual({error, no_matching_key}, verify(Token, [Jwk#{<<"alg">> => <<"PS256">>}])).

encryption_key_not_used_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{}, claims()),
    ?assertEqual({error, no_matching_key}, verify(Token, [Jwk#{<<"use">> => <<"enc">>}])),
    ?assertEqual(
        {error, no_matching_key}, verify(Token, [Jwk#{<<"key_ops">> => [<<"encrypt">>]}])
    ),
    ?assertMatch({ok, _}, verify(Token, [Jwk#{<<"key_ops">> => [<<"verify">>]}])).

wrong_curve_not_used_test() ->
    {Key, _} = livery_auth_jwt:keypair(<<"ES384">>, <<"k">>),
    {_, P256} = livery_auth_jwt:keypair(<<"ES256">>, <<"k">>),
    Token = livery_auth_jwt:mint(Key, #{}, claims()),
    ?assertEqual({error, no_matching_key}, verify(Token, [P256#{<<"alg">> => <<"ES384">>}])).

short_rsa_key_refused_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair_bits(<<"k">>, 1024),
    Token = livery_auth_jwt:mint(Key, #{}, claims()),
    ?assertEqual({error, bad_signature}, verify(Token, [Jwk])).

%% Without a kid, every fitting key is tried until one verifies.
tries_every_key_without_kid_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(<<"right">>),
    {_, Other} = livery_auth_jwt:rsa_keypair(<<"wrong">>),
    Token = livery_auth_jwt:mint(Key, #{}, claims()),
    ?assertMatch({ok, _}, verify(Token, [Other, Jwk])).

%%====================================================================
%% Header (RFC 7515)
%%====================================================================

crit_refused_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"crit">> => [<<"exp">>], <<"exp">> => 1}, claims()),
    ?assertEqual({error, {unsupported_crit, [<<"exp">>]}}, verify(Token, [Jwk])).

typ_checked_when_asked_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    At = livery_auth_jwt:mint(Key, #{<<"typ">> => <<"application/AT+JWT">>}, claims()),
    Plain = livery_auth_jwt:mint(Key, #{}, claims()),
    ?assertMatch({ok, _}, verify(At, [Jwk], #{typ => <<"at+jwt">>})),
    ?assertEqual({error, {invalid_typ, <<"JWT">>}}, verify(Plain, [Jwk], #{typ => <<"at+jwt">>})),
    ?assertMatch({ok, _}, verify(Plain, [Jwk])).

%%====================================================================
%% Claims (RFC 7519, RFC 9068)
%%====================================================================

fractional_numeric_date_accepted_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{}, #{<<"exp">> => ?NOW + 0.5}),
    ?assertMatch({ok, _}, verify(Token, [Jwk])).

non_numeric_date_refused_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{}, #{<<"exp">> => <<"tomorrow">>}),
    ?assertEqual({error, {invalid_claim, <<"exp">>}}, verify(Token, [Jwk])).

required_claims_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{}, claims()),
    ?assertEqual(
        {error, {missing_claim, <<"jti">>}},
        verify(Token, [Jwk], #{required_claims => [<<"sub">>, <<"jti">>]})
    ).

access_token(Overrides) ->
    maps:merge(
        #{
            <<"iss">> => <<"https://as.example">>,
            <<"aud">> => <<"https://api.example">>,
            <<"sub">> => <<"alice">>,
            <<"client_id">> => <<"app">>,
            <<"iat">> => ?NOW,
            <<"exp">> => ?NOW + 60,
            <<"jti">> => <<"1">>
        },
        Overrides
    ).

profile_opts() ->
    #{
        profile => access_token,
        issuer => <<"https://as.example">>,
        audience => <<"https://api.example">>
    }.

access_token_profile_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Good = livery_auth_jwt:mint(Key, #{<<"typ">> => <<"at+jwt">>}, access_token(#{})),
    NoClient = livery_auth_jwt:mint(
        Key, #{<<"typ">> => <<"at+jwt">>}, maps:remove(<<"client_id">>, access_token(#{}))
    ),
    WrongTyp = livery_auth_jwt:mint(Key, #{}, access_token(#{})),
    ?assertMatch({ok, _}, verify(Good, [Jwk], profile_opts())),
    ?assertEqual(
        {error, {missing_claim, <<"client_id">>}}, verify(NoClient, [Jwk], profile_opts())
    ),
    ?assertEqual({error, {invalid_typ, <<"JWT">>}}, verify(WrongTyp, [Jwk], profile_opts())).

access_token_profile_needs_issuer_and_audience_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(Key, #{<<"typ">> => <<"at+jwt">>}, access_token(#{})),
    ?assertEqual(
        {error, {missing_option, issuer}},
        verify(Token, [Jwk], maps:remove(issuer, profile_opts()))
    ),
    ?assertEqual(
        {error, {missing_option, audience}},
        verify(Token, [Jwk], maps:remove(audience, profile_opts()))
    ).

scope_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Space = livery_auth_jwt:mint(Key, #{}, (claims())#{<<"scope">> => <<"a b">>}),
    Scp = livery_auth_jwt:mint(Key, #{}, (claims())#{<<"scp">> => [<<"a">>]}),
    ?assertMatch({ok, _}, verify(Space, [Jwk], #{scope => [<<"b">>, <<"a">>]})),
    ?assertMatch({ok, _}, verify(Scp, [Jwk], #{scope => [<<"a">>]})),
    ?assertEqual(
        {error, {insufficient_scope, [<<"c">>]}},
        verify(Space, [Jwk], #{scope => [<<"a">>, <<"c">>]})
    ).

%%====================================================================
%% Bearer middleware challenges (RFC 6750 3)
%%====================================================================

run(State, Headers) ->
    Cap = livery_test_adapter:run(
        [{livery_auth_bearer, State}],
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        #{headers => Headers}
    ),
    {livery_test_adapter:status(Cap), livery_test_adapter:header(<<"www-authenticate">>, Cap)}.

bearer(Token) -> [{<<"authorization">>, <<"Bearer ", Token/binary>>}].

challenge_without_token_test() ->
    {_Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    ?assertEqual(
        {401, <<"Bearer realm=\"orders\"">>},
        run(#{keys => [Jwk], realm => <<"orders">>}, [])
    ).

challenge_for_invalid_token_test() ->
    {_Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    ?assertEqual(
        {401,
            <<"Bearer realm=\"orders\", error=\"invalid_token\", error_description=\"malformed token\"">>},
        run(#{keys => [Jwk], realm => <<"orders">>}, bearer(<<"nope">>))
    ).

challenge_for_insufficient_scope_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(),
    Token = livery_auth_jwt:mint(
        Key, #{}, #{<<"sub">> => <<"a">>, <<"exp">> => os:system_time(second) + 60}
    ),
    ?assertEqual(
        {403, <<"Bearer error=\"insufficient_scope\", scope=\"orders:write\"">>},
        run(#{keys => [Jwk], scope => [<<"orders:write">>]}, bearer(Token))
    ).

%%====================================================================
%% Helpers
%%====================================================================

unsigned(Alg) ->
    B64 = fun(B) -> base64:encode(B, #{mode => urlsafe, padding => false}) end,
    H = B64(iolist_to_binary(json:encode(#{<<"alg">> => Alg}))),
    P = B64(iolist_to_binary(json:encode(claims()))),
    <<H/binary, ".", P/binary, ".", (B64(<<"sig">>))/binary>>.
