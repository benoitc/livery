%% @doc Protected resource metadata (RFC 9728).
-module(livery_auth_resource_tests).

-include_lib("eunit/include/eunit.hrl").

well_known_path_test() ->
    ?assertEqual(
        <<"/.well-known/oauth-protected-resource">>,
        livery_auth_resource:well_known_path(<<"https://api.example/">>)
    ),
    ?assertEqual(
        <<"/.well-known/oauth-protected-resource/orders">>,
        livery_auth_resource:well_known_path(<<"https://api.example/orders/">>)
    ),
    ?assertEqual(
        <<"https://api.example:8443/.well-known/oauth-protected-resource/orders">>,
        livery_auth_resource:well_known_url(<<"https://api.example:8443/orders?x=1">>)
    ).

minimal_metadata_test() ->
    ?assertEqual(
        #{
            <<"resource">> => <<"https://api.example">>,
            <<"bearer_methods_supported">> => [<<"header">>],
            <<"tls_client_certificate_bound_access_tokens">> => false
        },
        livery_auth_resource:metadata(#{resource => <<"https://api.example">>})
    ).

%% The binding fields follow the same options the middlewares take.
binding_fields_test() ->
    Meta = livery_auth_resource:metadata(#{
        resource => <<"https://api.example">>,
        authorization_servers => [<<"https://as.example">>],
        scopes_supported => [<<"a">>],
        binding => any,
        algorithms => [<<"ES256">>]
    }),
    ?assertMatch(
        #{
            <<"authorization_servers">> := [<<"https://as.example">>],
            <<"scopes_supported">> := [<<"a">>],
            <<"tls_client_certificate_bound_access_tokens">> := true,
            <<"dpop_signing_alg_values_supported">> := [<<"ES256">>],
            <<"dpop_bound_access_tokens_required">> := false
        },
        Meta
    ),
    ?assertMatch(
        #{<<"dpop_bound_access_tokens_required">> := true},
        livery_auth_resource:metadata(#{resource => <<"https://api.example">>, binding => dpop})
    ).

handler_serves_json_test() ->
    Handler = livery_auth_resource:handler(#{resource => <<"https://api.example">>}),
    Cap = livery_test_adapter:run([], Handler, #{}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertMatch(
        <<"application/json", _/binary>>, livery_test_adapter:header(<<"content-type">>, Cap)
    ),
    ?assertMatch(
        #{<<"resource">> := <<"https://api.example">>},
        json:decode(livery_test_adapter:body(Cap))
    ).
