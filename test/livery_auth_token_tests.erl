%% @doc Token endpoint client (RFC 6749 3.2 and 5, RFC 7523 with RFC 10070,
%% RFC 8705, RFC 8707).
-module(livery_auth_token_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ENDPOINT, <<"https://as.example/token">>).
-define(ISSUER, <<"https://as.example">>).
-define(NOW, 1_700_000_000).

%% Run a token request and return what was sent and what came back.
exchange(Grant, Params, Opts) ->
    exchange(
        Grant,
        Params,
        Opts,
        {200, #{<<"access_token">> => <<"at">>, <<"token_type">> => <<"Bearer">>}}
    ).

exchange(Grant, Params, Opts, {Status, Reply}) ->
    Self = self(),
    Handler = fun(Req) ->
        Self ! {sent, Req},
        Body =
            case Reply of
                #{} -> iolist_to_binary(json:encode(Reply));
                Raw when is_binary(Raw) -> Raw
            end,
        {Status, [{<<"content-type">>, <<"application/json">>}], Body}
    end,
    Result = livery_auth_token:request(
        Grant,
        Params,
        maps:merge(
            #{
                token_endpoint => ?ENDPOINT,
                client_id => <<"app">>,
                client_secret => <<"s3cret">>,
                adapter => livery_client_fun_adapter,
                adapter_opts => #{handler => Handler},
                now => ?NOW
            },
            Opts
        )
    ),
    receive
        {sent, Req} -> {Req, Result}
    after 1000 -> error(nothing_sent)
    end.

form(Req) ->
    {full, Body} = maps:get(body, Req),
    uri_string:dissect_query(iolist_to_binary(Body)).

header(Name, Req) -> proplists:get_value(Name, maps:get(headers, Req)).

%%====================================================================
%% Requests
%%====================================================================

client_credentials_basic_test() ->
    {Req, {ok, _}} = exchange(
        client_credentials,
        #{scope => [<<"a">>, <<"b">>], resource => [<<"https://api.example">>]},
        #{client_id => <<"app:1">>, client_secret => <<"p w+">>}
    ),
    ?assertEqual(post, maps:get(method, Req)),
    ?assertEqual(?ENDPOINT, maps:get(url, Req)),
    <<"Basic ", B64/binary>> = header(<<"authorization">>, Req),
    ?assertEqual(<<"app%3A1:p+w%2B">>, base64:decode(B64)),
    ?assertEqual(
        [
            {<<"grant_type">>, <<"client_credentials">>},
            {<<"scope">>, <<"a b">>},
            {<<"resource">>, <<"https://api.example">>}
        ],
        form(Req)
    ).

client_secret_post_test() ->
    {Req, {ok, _}} = exchange(client_credentials, #{}, #{client_auth => client_secret_post}),
    ?assertEqual(undefined, header(<<"authorization">>, Req)),
    ?assertMatch(
        [{<<"client_id">>, <<"app">>}, {<<"client_secret">>, <<"s3cret">>} | _], form(Req)
    ).

public_and_mtls_clients_send_only_their_id_test() ->
    [
        begin
            {Req, {ok, _}} = exchange(client_credentials, #{}, #{client_auth => Method}),
            ?assertEqual(undefined, header(<<"authorization">>, Req)),
            ?assertEqual(
                [{<<"client_id">>, <<"app">>}, {<<"grant_type">>, <<"client_credentials">>}],
                form(Req)
            )
        end
     || Method <- [none, tls_client_auth]
    ].

authorization_code_test() ->
    {Req, {ok, _}} = exchange(
        authorization_code,
        #{code => <<"c">>, redirect_uri => <<"https://app.example/cb">>, code_verifier => <<"v">>},
        #{}
    ),
    ?assertEqual(
        [
            {<<"grant_type">>, <<"authorization_code">>},
            {<<"code">>, <<"c">>},
            {<<"redirect_uri">>, <<"https://app.example/cb">>},
            {<<"code_verifier">>, <<"v">>}
        ],
        form(Req)
    ).

%% RFC 7523 2.2 with RFC 10070: issuer as the sole audience, explicit typ.
private_key_jwt_test() ->
    {Key, Jwk} = livery_auth_jwt:keypair(<<"ES256">>, <<"k1">>),
    {Req, {ok, _}} = exchange(client_credentials, #{}, #{
        client_auth => private_key_jwt, private_key => Key, key_id => <<"k1">>, issuer => ?ISSUER
    }),
    Form = form(Req),
    ?assertEqual(
        <<"urn:ietf:params:oauth:client-assertion-type:jwt-bearer">>,
        proplists:get_value(<<"client_assertion_type">>, Form)
    ),
    Assertion = proplists:get_value(<<"client_assertion">>, Form),
    [H | _] = binary:split(Assertion, <<".">>),
    ?assertMatch(
        {ok, #{<<"typ">> := <<"client-authentication+jwt">>, <<"kid">> := <<"k1">>}},
        livery_auth_jose:decode_json(H)
    ),
    {ok, Claims} = livery_auth:verify(Assertion, #{keys => [Jwk], now => ?NOW}),
    ?assertMatch(
        #{<<"iss">> := <<"app">>, <<"sub">> := <<"app">>, <<"aud">> := ?ISSUER, <<"jti">> := _},
        Claims
    ),
    ?assertEqual(60, maps:get(<<"exp">>, Claims) - maps:get(<<"iat">>, Claims)),
    ?assertEqual(undefined, header(<<"authorization">>, Req)).

private_key_jwt_legacy_audience_test() ->
    {Key, Jwk} = livery_auth_jwt:keypair(<<"ES256">>, <<"k1">>),
    {Req, {ok, _}} = exchange(client_credentials, #{}, #{
        client_auth => private_key_jwt, private_key => Key, assertion_audience => token_endpoint
    }),
    {ok, Claims} = livery_auth:verify(
        proplists:get_value(<<"client_assertion">>, form(Req)), #{keys => [Jwk], now => ?NOW}
    ),
    ?assertEqual(?ENDPOINT, maps:get(<<"aud">>, Claims)).

private_key_jwt_needs_issuer_test() ->
    {Key, _} = livery_auth_jwt:keypair(<<"ES256">>, <<"k1">>),
    ?assertEqual(
        {error, {missing_option, issuer}},
        livery_auth_token:request(client_credentials, #{}, #{
            token_endpoint => ?ENDPOINT,
            client_id => <<"app">>,
            client_auth => private_key_jwt,
            private_key => Key
        })
    ).

%%====================================================================
%% Responses
%%====================================================================

success_response_test() ->
    Reply = #{
        <<"access_token">> => <<"at">>,
        <<"token_type">> => <<"Bearer">>,
        <<"expires_in">> => 3600,
        <<"refresh_token">> => <<"rt">>,
        <<"id_token">> => <<"it">>,
        <<"scope">> => <<"a">>
    },
    {_, {ok, Token}} = exchange(client_credentials, #{}, #{}, {200, Reply}),
    ?assertMatch(
        #{
            access_token := <<"at">>,
            token_type := <<"Bearer">>,
            expires_at := 1_700_003_600,
            refresh_token := <<"rt">>,
            id_token := <<"it">>,
            scope := <<"a">>
        },
        Token
    ).

oauth_error_response_test() ->
    Reply = #{<<"error">> => <<"invalid_client">>, <<"error_description">> => <<"no">>},
    ?assertMatch(
        {_, {error, {oauth_error, <<"invalid_client">>, <<"no">>}}},
        exchange(client_credentials, #{}, #{}, {401, Reply})
    ).

non_json_error_test() ->
    ?assertMatch(
        {_, {error, {http_status, 502}}},
        exchange(client_credentials, #{}, #{}, {502, <<"bad gateway">>})
    ).

missing_access_token_test() ->
    ?assertMatch(
        {_, {error, invalid_response}},
        exchange(client_credentials, #{}, #{}, {200, #{<<"token_type">> => <<"Bearer">>}})
    ).
