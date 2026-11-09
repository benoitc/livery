%% @doc DPoP (RFC 9449) and certificate-bound tokens (RFC 8705) at the
%% resource server: proof checks, thumbprints, and the bearer middleware
%% refusing tokens presented by the wrong client.
-module(livery_auth_dpop_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, 1_700_000_000).
-define(URL, <<"https://api.example/orders">>).
-define(TOKEN, <<"access-token">>).

%%====================================================================
%% Fixtures
%%====================================================================

%% A fresh replay store for every proof check, so tests do not share
%% state; `replay_test' uses the real one.
opts() ->
    Seen = ets:new(seen, [public]),
    #{
        now => ?NOW,
        dpop_replay => fun(Key, _Exp) ->
            case ets:insert_new(Seen, {Key}) of
                true -> fresh;
                false -> replayed
            end
        end
    }.

key() -> livery_auth_jwt:keypair(<<"ES256">>, <<"k">>).

public(Jwk) -> maps:without([<<"kid">>, <<"alg">>], Jwk).

proof_claims() ->
    #{
        <<"jti">> => integer_to_binary(erlang:unique_integer([positive])),
        <<"htm">> => <<"GET">>,
        <<"htu">> => ?URL,
        <<"iat">> => ?NOW,
        <<"ath">> => ath(?TOKEN)
    }.

proof(Key, Jwk) -> proof(Key, Jwk, #{}, #{}).

proof({Alg, _} = Key, Jwk, ClaimOverrides, HeaderOverrides) ->
    Header = maps:merge(
        #{<<"typ">> => <<"dpop+jwt">>, <<"alg">> => Alg, <<"jwk">> => public(Jwk)}, HeaderOverrides
    ),
    livery_auth_jwt:mint_raw(Key, Header, maps:merge(proof_claims(), ClaimOverrides)).

req(Proofs) ->
    livery_req:new(#{
        method => <<"GET">>,
        scheme => <<"https">>,
        authority => <<"api.example">>,
        path => <<"/orders">>,
        headers => [{<<"dpop">>, P} || P <- Proofs]
    }).

ath(Token) -> b64(crypto:hash(sha256, Token)).

b64(B) -> base64:encode(B, #{mode => urlsafe, padding => false}).

check(Proofs) -> check(Proofs, opts()).

check(Proofs, Opts) -> livery_auth_dpop:verify_proof(req(Proofs), ?TOKEN, Opts).

%%====================================================================
%% Thumbprint (RFC 7638)
%%====================================================================

%% The example of RFC 7638 section 3.1.
rfc7638_example_thumbprint_test() ->
    Jwk = #{
        <<"kty">> => <<"RSA">>,
        <<"e">> => <<"AQAB">>,
        <<"alg">> => <<"RS256">>,
        <<"kid">> => <<"2011-04-29">>,
        <<"n">> =>
            <<"0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw">>
    },
    ?assertEqual(
        <<"NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs">>, livery_auth_dpop:thumbprint(Jwk)
    ).

%%====================================================================
%% Proof checks (RFC 9449 4.3)
%%====================================================================

valid_proof_returns_thumbprint_test() ->
    {Key, Jwk} = key(),
    ?assertEqual({ok, livery_auth_dpop:thumbprint(Jwk)}, check([proof(Key, Jwk)])).

every_algorithm_test_() ->
    [
        {Alg, fun() ->
            {Key, Jwk} = livery_auth_jwt:keypair(Alg, <<"k">>),
            ?assertMatch({ok, _}, check([proof(Key, Jwk)]))
        end}
     || Alg <- [<<"RS256">>, <<"PS256">>, <<"ES384">>, <<"Ed25519">>]
    ].

missing_and_multiple_proofs_test() ->
    {Key, Jwk} = key(),
    ?assertEqual({error, missing_proof}, check([])),
    ?assertEqual({error, multiple_proofs}, check([proof(Key, Jwk), proof(Key, Jwk)])).

wrong_claims_test_() ->
    {Key, Jwk} = key(),
    Cases = [
        {<<"htm">>, #{<<"htm">> => <<"POST">>}},
        {<<"htu">>, #{<<"htu">> => <<"https://api.example/other">>}},
        {<<"htu">>, #{<<"htu">> => <<"https://evil.example/orders">>}},
        {<<"ath">>, #{<<"ath">> => ath(<<"another token">>)}},
        {<<"ath">>, #{<<"ath">> => null}},
        {<<"iat">>, #{<<"iat">> => ?NOW - 61}},
        {<<"iat">>, #{<<"iat">> => ?NOW + 5}},
        {<<"jti">>, #{<<"jti">> => <<>>}}
    ],
    [
        {Name, ?_assertEqual({error, {invalid_proof, Name}}, check([proof(Key, Jwk, C, #{})]))}
     || {Name, C} <- Cases
    ].

%% htu is compared after normalisation, without query and fragment.
htu_normalised_test() ->
    {Key, Jwk} = key(),
    Proof = proof(Key, Jwk, #{<<"htu">> => <<"HTTPS://API.example:443/orders?x=1#f">>}, #{}),
    ?assertMatch({ok, _}, check([Proof])).

wrong_header_test_() ->
    {Key, Jwk} = key(),
    {_, Ed} = livery_auth_jwt:keypair(<<"Ed25519">>, <<"e">>),
    [
        {"typ",
            ?_assertEqual(
                {error, {invalid_proof, <<"typ">>}},
                check([proof(Key, Jwk, #{}, #{<<"typ">> => <<"JWT">>})])
            )},
        {"private key in jwk",
            ?_assertEqual(
                {error, {invalid_proof, <<"jwk">>}},
                check([proof(Key, Jwk, #{}, #{<<"jwk">> => (public(Jwk))#{<<"d">> => <<"AAAA">>}})])
            )},
        {"no jwk",
            ?_assertEqual(
                {error, {invalid_proof, <<"jwk">>}},
                check([proof(Key, Jwk, #{}, #{<<"jwk">> => null})])
            )},
        {"signed by another key",
            ?_assertEqual(
                {error, {invalid_proof, <<"signature">>}},
                check([proof(Key, Jwk, #{}, #{<<"jwk">> => public(Ed)})])
            )},
        {"alg not allowed",
            ?_assertEqual(
                {error, {invalid_proof, <<"alg">>}},
                check([proof(Key, Jwk)], (opts())#{algorithms => [<<"RS256">>]})
            )}
    ].

%% The default store, owned by the livery application.
replay_test_() ->
    {setup,
        fun() ->
            {ok, Apps} = application:ensure_all_started(livery),
            Apps
        end,
        fun(Apps) -> [application:stop(A) || A <- lists:reverse(Apps)] end, fun() ->
            {Key, Jwk} = key(),
            Proof = proof(Key, Jwk),
            Opts = #{now => ?NOW},
            ?assertMatch({ok, _}, check([Proof], Opts)),
            ?assertEqual({error, replayed_proof}, check([Proof], Opts))
        end}.

%% Behind a proxy the public URL is supplied by the application.
dpop_url_override_test() ->
    {Key, Jwk} = key(),
    Proof = proof(Key, Jwk, #{<<"htu">> => <<"https://public.example/api/orders">>}, #{}),
    Opts = (opts())#{dpop_url => fun(_Req) -> <<"https://public.example/api/orders">> end},
    ?assertMatch({ok, _}, check([Proof], Opts)).

%%====================================================================
%% Bearer middleware: DPoP-bound and certificate-bound tokens
%%====================================================================

run(State, Req) ->
    Cap = livery_test_adapter:run(
        [{livery_auth_bearer, mw(State)}],
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        Req
    ),
    {livery_test_adapter:status(Cap), livery_test_adapter:header(<<"www-authenticate">>, Cap)}.

%% An access token signed by the issuer, bound with `Cnf'.
issued(Cnf) ->
    {IssKey, IssJwk} = livery_auth_jwt:rsa_keypair(<<"iss">>),
    Claims = #{
        <<"sub">> => <<"alice">>, <<"exp">> => os:system_time(second) + 60, <<"cnf">> => Cnf
    },
    {livery_auth_jwt:mint(IssKey, #{<<"kid">> => <<"iss">>}, Claims), IssJwk}.

live_proof(Key, Jwk, Token) ->
    proof(Key, Jwk, #{<<"iat">> => os:system_time(second), <<"ath">> => ath(Token)}, #{}).

request(Scheme, Token, Proofs) ->
    #{
        method => <<"GET">>,
        scheme => <<"https">>,
        authority => <<"api.example">>,
        path => <<"/orders">>,
        headers => [{<<"authorization">>, <<Scheme/binary, " ", Token/binary>>}] ++
            [{<<"dpop">>, P} || P <- Proofs]
    }.

dpop_bound_token_accepted_test() ->
    {Key, Jwk} = key(),
    {Token, IssJwk} = issued(#{<<"jkt">> => livery_auth_dpop:thumbprint(Jwk)}),
    State = #{keys => [IssJwk], dpop => true},
    ?assertMatch({200, _}, run(State, request(<<"DPoP">>, Token, [live_proof(Key, Jwk, Token)]))).

dpop_bound_token_refused_as_bearer_test() ->
    {_Key, Jwk} = key(),
    {Token, IssJwk} = issued(#{<<"jkt">> => livery_auth_dpop:thumbprint(Jwk)}),
    {Status, Challenge} = run(#{keys => [IssJwk], dpop => true}, request(<<"Bearer">>, Token, [])),
    ?assertEqual(401, Status),
    ?assertMatch({_, _}, binary:match(Challenge, <<"Bearer error=\"invalid_token\"">>)),
    ?assertMatch({_, _}, binary:match(Challenge, <<"DPoP algs=">>)).

dpop_proof_for_other_key_refused_test() ->
    {_Key, Jwk} = key(),
    {Other, OtherJwk} = livery_auth_jwt:keypair(<<"ES256">>, <<"o">>),
    {Token, IssJwk} = issued(#{<<"jkt">> => livery_auth_dpop:thumbprint(Jwk)}),
    {Status, Challenge} = run(
        #{keys => [IssJwk], dpop => true},
        request(<<"DPoP">>, Token, [live_proof(Other, OtherJwk, Token)])
    ),
    ?assertEqual(401, Status),
    ?assertMatch({_, _}, binary:match(Challenge, <<"DPoP error=\"invalid_dpop_proof\"">>)).

unbound_token_refused_as_dpop_test() ->
    {Key, Jwk} = key(),
    {Token, IssJwk} = issued(#{}),
    ?assertMatch(
        {401, _},
        run(
            #{keys => [IssJwk], dpop => true},
            request(<<"DPoP">>, Token, [live_proof(Key, Jwk, Token)])
        )
    ).

binding_required_test() ->
    {Token, IssJwk} = issued(#{}),
    {Status, Challenge} = run(
        #{keys => [IssJwk], binding => dpop}, request(<<"Bearer">>, Token, [])
    ),
    ?assertEqual(401, Status),
    %% Bearer is not advertised when only DPoP tokens are accepted.
    ?assertMatch(<<"DPoP error=\"invalid_token\"", _/binary>>, Challenge).

cert_bound(Der) -> b64(crypto:hash(sha256, Der)).

certificate_bound_token_test() ->
    Der = <<"a client certificate">>,
    {Token, IssJwk} = issued(#{<<"x5t#S256">> => cert_bound(Der)}),
    State = #{keys => [IssJwk]},
    Base = request(<<"Bearer">>, Token, []),
    ?assertMatch({200, _}, run(State, Base#{tls => #{verified => true, cert => Der}})),
    ?assertMatch(
        {401, _}, run(State, Base#{tls => #{verified => true, cert => <<"another one">>}})
    ),
    ?assertMatch({401, _}, run(State, Base#{tls => #{verified => false}})),
    ?assertMatch({401, _}, run(State, Base)).

resource_metadata_in_challenge_test() ->
    {_, IssJwk} = issued(#{}),
    Url = <<"https://api.example/.well-known/oauth-protected-resource">>,
    ?assertEqual(
        {401, <<"Bearer resource_metadata=\"", Url/binary, "\"">>},
        run(#{keys => [IssJwk], resource_metadata => Url}, #{headers => []})
    ).

%% Middleware state with a private replay store.
mw(State) ->
    maps:merge(maps:with([dpop_replay], opts()), State).
