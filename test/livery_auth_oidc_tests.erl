-module(livery_auth_oidc_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

-define(NOW, 1_700_000_000).

%%====================================================================
%% OIDC discovery (injected fetch, no network)
%%====================================================================

well_known_url_test() ->
    ?assertEqual(
        <<"https://i.example/.well-known/openid-configuration">>,
        livery_auth_oidc:well_known_url(<<"https://i.example">>)
    ),
    %% trailing slash trimmed
    ?assertEqual(
        <<"https://i.example/.well-known/openid-configuration">>,
        livery_auth_oidc:well_known_url(<<"https://i.example/">>)
    ).

discover_parses_config_test() ->
    Doc = #{
        <<"issuer">> => <<"https://i.example">>,
        <<"jwks_uri">> => <<"https://i.example/jwks">>
    },
    Fetch = fun(<<"https://i.example/.well-known/openid-configuration">>) ->
        {ok, iolist_to_binary(json:encode(Doc))}
    end,
    {ok, Cfg} = livery_auth_oidc:discover(
        <<"https://i.example">>,
        #{fetch => Fetch}
    ),
    ?assertEqual(<<"https://i.example/jwks">>, maps:get(<<"jwks_uri">>, Cfg)).

discover(Issuer, Doc) ->
    Fetch = fun(_) -> {ok, iolist_to_binary(json:encode(Doc))} end,
    livery_auth_oidc:discover(Issuer, #{fetch => Fetch}).

%% Discovery 1.0 section 4.3: a document naming another issuer, or none,
%% must not be used.
discover_rejects_other_issuer_test() ->
    Doc = #{
        <<"issuer">> => <<"https://evil.example">>,
        <<"jwks_uri">> => <<"https://evil.example/jwks">>
    },
    ?assertEqual({error, issuer_mismatch}, discover(<<"https://i.example">>, Doc)).

discover_rejects_missing_issuer_test() ->
    Doc = #{<<"jwks_uri">> => <<"https://evil.example/jwks">>},
    ?assertEqual({error, invalid_discovery}, discover(<<"https://i.example">>, Doc)).

%% The match is exact: the trailing slash is part of the issuer.
discover_keeps_trailing_slash_issuer_test() ->
    Doc = #{<<"issuer">> => <<"https://i.example/">>},
    ?assertMatch({ok, _}, discover(<<"https://i.example/">>, Doc)),
    ?assertEqual({error, issuer_mismatch}, discover(<<"https://i.example">>, Doc)).

%% RFC 8414 3.1: the well-known segment goes before the issuer's path.
oauth_well_known_url_test() ->
    ?assertEqual(
        <<"https://as.example/.well-known/oauth-authorization-server">>,
        livery_auth_oidc:oauth_well_known_url(<<"https://as.example/">>)
    ),
    ?assertEqual(
        <<"https://as.example/.well-known/oauth-authorization-server/tenant">>,
        livery_auth_oidc:oauth_well_known_url(<<"https://as.example/tenant">>)
    ).

%% RFC 8414 3.3: the metadata must name the issuer it was fetched for.
discover_oauth_checks_issuer_test() ->
    Fetch = fun(Doc) ->
        fun(<<"https://as.example/.well-known/oauth-authorization-server/t">>) ->
            {ok, iolist_to_binary(json:encode(Doc))}
        end
    end,
    Issuer = <<"https://as.example/t">>,
    ?assertMatch(
        {ok, #{<<"token_endpoint">> := _}},
        livery_auth_oidc:discover_oauth(Issuer, #{
            fetch => Fetch(#{<<"issuer">> => Issuer, <<"token_endpoint">> => <<"x">>})
        })
    ),
    ?assertEqual(
        {error, issuer_mismatch},
        livery_auth_oidc:discover_oauth(Issuer, #{
            fetch => Fetch(#{<<"issuer">> => <<"https://as.example">>})
        })
    ).

discover_propagates_fetch_error_test() ->
    Fetch = fun(_) -> {error, nxdomain} end,
    ?assertEqual(
        {error, nxdomain},
        livery_auth_oidc:discover(
            <<"https://i.example">>,
            #{fetch => Fetch}
        )
    ).

%%====================================================================
%% JWKS fetch + cache + rotation
%%====================================================================

jwks_from_json_test() ->
    {_Key, Jwk} = livery_auth_jwt:rsa_keypair(<<"k1">>),
    Body = iolist_to_binary(json:encode(#{<<"keys">> => [Jwk]})),
    ?assertEqual({ok, [Jwk]}, livery_auth_jwks:from_json(Body)).

jwks_keys_fetches_and_caches_test() ->
    {_Key, Jwk} = livery_auth_jwt:rsa_keypair(<<"cache1">>),
    Uri = <<"https://i.example/jwks-cache-1">>,
    Counter = counters:new(1, []),
    Fetch = fun(_) ->
        counters:add(Counter, 1, 1),
        {ok, iolist_to_binary(json:encode(#{<<"keys">> => [Jwk]}))}
    end,
    {ok, [Jwk]} = livery_auth_jwks:keys(Uri, #{fetch => Fetch}),
    {ok, [Jwk]} = livery_auth_jwks:keys(Uri, #{fetch => Fetch}),
    %% Second call served from cache: fetch invoked exactly once.
    ?assertEqual(1, counters:get(Counter, 1)).

jwks_refresh_refetches_test() ->
    {_K1, Jwk1} = livery_auth_jwt:rsa_keypair(<<"old">>),
    {_K2, Jwk2} = livery_auth_jwt:rsa_keypair(<<"new">>),
    Uri = <<"https://i.example/jwks-rotate">>,
    Ref = make_ref(),
    put({jwks_set, Ref}, [Jwk1]),
    Fetch = fun(_) ->
        {ok, iolist_to_binary(json:encode(#{<<"keys">> => get({jwks_set, Ref})}))}
    end,
    {ok, [Jwk1]} = livery_auth_jwks:keys(Uri, #{fetch => Fetch}),
    put({jwks_set, Ref}, [Jwk2]),
    %% cached value is still the old one
    {ok, [Jwk1]} = livery_auth_jwks:keys(Uri, #{fetch => Fetch}),
    %% refresh picks up the new set
    {ok, [Jwk2]} = livery_auth_jwks:refresh(Uri, #{fetch => Fetch}).

%%====================================================================
%% Bearer middleware with jwks_uri (rotation)
%%====================================================================

bearer_resolves_keys_from_jwks_uri_test() ->
    {Key, Jwk} = livery_auth_jwt:rsa_keypair(<<"ju1">>),
    Uri = <<"https://i.example/jwks-bearer-1">>,
    Fetch = fun(_) ->
        {ok, iolist_to_binary(json:encode(#{<<"keys">> => [Jwk]}))}
    end,
    Token = livery_auth_jwt:mint(
        Key,
        #{<<"kid">> => <<"ju1">>},
        #{<<"sub">> => <<"x">>, <<"exp">> => future()}
    ),
    Stack = [{livery_auth_bearer, #{jwks_uri => Uri, fetch => Fetch}}],
    Cap = livery_test_adapter:run(
        Stack,
        fun(R) ->
            #{<<"sub">> := S} = livery_ext:user(R),
            livery_resp:text(200, S)
        end,
        #{headers => [{<<"authorization">>, <<"Bearer ", Token/binary>>}]}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"x">>, livery_test_adapter:body(Cap)).

bearer_refreshes_jwks_on_rotation_test() ->
    %% Token signed by a key the cache doesn't have yet; the
    %% middleware should refresh and then accept it.
    {Key, NewJwk} = livery_auth_jwt:rsa_keypair(<<"rotated">>),
    {_OldK, OldJwk} = livery_auth_jwt:rsa_keypair(<<"stale">>),
    Uri = <<"https://i.example/jwks-bearer-rotate">>,
    Ref = make_ref(),
    put({rotate_set, Ref}, [OldJwk]),
    Fetch = fun(_) ->
        {ok, iolist_to_binary(json:encode(#{<<"keys">> => get({rotate_set, Ref})}))}
    end,
    %% prime cache with the stale set
    {ok, [OldJwk]} = livery_auth_jwks:keys(Uri, #{fetch => Fetch}),
    %% issuer rotates keys
    put({rotate_set, Ref}, [NewJwk]),
    Token = livery_auth_jwt:mint(
        Key,
        #{<<"kid">> => <<"rotated">>},
        #{<<"sub">> => <<"y">>, <<"exp">> => future()}
    ),
    %% The cache was primed just now; an interval of 0 stands in for the
    %% rotation happening after the throttle window.
    Stack = [{livery_auth_bearer, #{jwks_uri => Uri, fetch => Fetch, min_refresh_interval => 0}}],
    Cap = livery_test_adapter:run(
        Stack,
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        #{headers => [{<<"authorization">>, <<"Bearer ", Token/binary>>}]}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)).

%% Tokens naming unknown key ids refetch the set at most once per
%% interval, so they cannot turn into one fetch per request.
bearer_throttles_jwks_refresh_test() ->
    {Key, _Jwk} = livery_auth_jwt:rsa_keypair(<<"unknown">>),
    {_OtherK, OtherJwk} = livery_auth_jwt:rsa_keypair(<<"known">>),
    Uri = <<"https://i.example/jwks-bearer-throttle">>,
    Counter = counters:new(1, []),
    Fetch = fun(_) ->
        counters:add(Counter, 1, 1),
        {ok, iolist_to_binary(json:encode(#{<<"keys">> => [OtherJwk]}))}
    end,
    Token = livery_auth_jwt:mint(
        Key, #{<<"kid">> => <<"unknown">>}, #{<<"sub">> => <<"y">>, <<"exp">> => future()}
    ),
    Run = fun(Interval) ->
        Stack = [
            {livery_auth_bearer, #{
                jwks_uri => Uri, fetch => Fetch, min_refresh_interval => Interval
            }}
        ],
        livery_test_adapter:status(
            livery_test_adapter:run(
                Stack,
                fun(_R) -> livery_resp:text(200, <<"ok">>) end,
                #{headers => [{<<"authorization">>, <<"Bearer ", Token/binary>>}]}
            )
        )
    end,
    [401 = Run(60000) || _ <- lists:seq(1, 5)],
    ?assertEqual(1, counters:get(Counter, 1)),
    401 = Run(0),
    ?assertEqual(2, counters:get(Counter, 1)).

%%====================================================================
%% Helpers
%%====================================================================

future() ->
    os:system_time(second) + 3600.
