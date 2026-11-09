%% @doc OpenID Connect login: authorization code with PKCE, state, nonce,
%% RFC 9207 issuer check and ID token validation (OIDC Core 3.1.3.7).
-module(livery_auth_login_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ISS, <<"https://id.example">>).
-define(CLIENT, <<"my-app">>).
-define(SECRET, <<"a long session secret">>).

%%====================================================================
%% Fixtures
%%====================================================================

issuer_key() ->
    case get(issuer_key) of
        undefined ->
            K = livery_auth_jwt:keypair(<<"RS256">>, <<"id-key">>),
            put(issuer_key, K),
            K;
        K ->
            K
    end.

provider() ->
    #{
        <<"issuer">> => ?ISS,
        <<"authorization_endpoint">> => <<?ISS/binary, "/authorize">>,
        <<"token_endpoint">> => <<?ISS/binary, "/token">>,
        <<"id_token_signing_alg_values_supported">> => [<<"RS256">>]
    }.

%% Login options; `Reply' builds the token endpoint answer from the form
%% the callback sends.
opts(Reply) ->
    {_Key, Jwk} = issuer_key(),
    #{
        provider => provider(),
        client_id => ?CLIENT,
        client_secret => <<"cs">>,
        redirect_uri => <<"https://app.example/auth/callback">>,
        scope => [<<"email">>],
        session => #{secret => ?SECRET},
        keys => [Jwk],
        adapter => livery_client_fun_adapter,
        adapter_opts => #{
            handler => fun(Req) ->
                {full, Body} = maps:get(body, Req),
                {200, [], iolist_to_binary(json:encode(Reply(uri_string:dissect_query(Body))))}
            end
        }
    }.

id_token(Nonce, Overrides) ->
    {Key, _} = issuer_key(),
    Now = os:system_time(second),
    Claims = maps:merge(
        #{
            <<"iss">> => ?ISS,
            <<"sub">> => <<"alice">>,
            <<"aud">> => ?CLIENT,
            <<"exp">> => Now + 300,
            <<"iat">> => Now,
            <<"nonce">> => Nonce,
            <<"email">> => <<"alice@example.org">>
        },
        Overrides
    ),
    livery_auth_jwt:mint(Key, #{<<"kid">> => <<"id-key">>}, Claims).

token_reply(IdToken) ->
    fun(_Form) ->
        #{
            <<"access_token">> => <<"at">>,
            <<"token_type">> => <<"Bearer">>,
            <<"id_token">> => IdToken
        }
    end.

%% Start a login and return what the browser would carry back.
start(Query) ->
    Cap = livery_test_adapter:run([], livery_auth_login:login(opts(token_reply(<<>>))), #{
        raw_query => Query
    }),
    302 = livery_test_adapter:status(Cap),
    Location = livery_test_adapter:header(<<"location">>, Cap),
    #{query := Q} = uri_string:parse(Location),
    Params = maps:from_list(uri_string:dissect_query(Q)),
    SetCookie = livery_test_adapter:header(<<"set-cookie">>, Cap),
    [Cookie | _] = binary:split(SetCookie, <<";">>),
    #{location => Location, params => Params, cookie => Cookie, set_cookie => SetCookie}.

callback(Login, Query, Opts) ->
    callback(Login, Query, Opts, [{<<"cookie">>, maps:get(cookie, Login)}]).

callback(_Login, Query, Opts, Headers) ->
    Cap = livery_test_adapter:run([], livery_auth_login:callback(Opts), #{
        raw_query => iolist_to_binary(uri_string:compose_query(Query)),
        headers => Headers
    }),
    {livery_test_adapter:status(Cap), Cap}.

ok_query(Login) ->
    #{params := #{<<"state">> := State}} = Login,
    [{<<"state">>, State}, {<<"code">>, <<"the-code">>}, {<<"iss">>, ?ISS}].

nonce(#{params := #{<<"nonce">> := N}}) -> N.

%%====================================================================
%% Login
%%====================================================================

login_redirect_test() ->
    #{location := Location, params := P, set_cookie := SetCookie} = start(<<>>),
    ?assertMatch(<<"https://id.example/authorize?", _/binary>>, Location),
    ?assertMatch(
        #{
            <<"response_type">> := <<"code">>,
            <<"client_id">> := ?CLIENT,
            <<"redirect_uri">> := <<"https://app.example/auth/callback">>,
            <<"scope">> := <<"openid email">>,
            <<"code_challenge_method">> := <<"S256">>,
            <<"state">> := _,
            <<"nonce">> := _,
            <<"code_challenge">> := _
        },
        P
    ),
    [
        ?assertMatch({_, _}, binary:match(SetCookie, A))
     || A <- [
            <<"session_login=">>,
            <<"Path=/auth/callback">>,
            <<"Max-Age=600">>,
            <<"SameSite=Lax">>,
            <<"Secure">>,
            <<"HttpOnly">>
        ]
    ].

%% The challenge is the S256 of the verifier the callback will send.
pkce_verifier_matches_challenge_test() ->
    Login = start(<<>>),
    Self = self(),
    Opts = opts(fun(Form) ->
        Self ! {verifier, proplists:get_value(<<"code_verifier">>, Form)},
        (token_reply(id_token(nonce(Login), #{})))(Form)
    end),
    {302, _} = callback(Login, ok_query(Login), Opts),
    Verifier =
        receive
            {verifier, V} -> V
        after 1000 -> error(no_verifier)
        end,
    Challenge = base64:encode(crypto:hash(sha256, Verifier), #{mode => urlsafe, padding => false}),
    ?assertEqual(Challenge, maps:get(<<"code_challenge">>, maps:get(params, Login))).

%%====================================================================
%% Callback
%%====================================================================

signs_in_and_redirects_test() ->
    Login = start(<<"return_to=/orders%3Fpage%3D2">>),
    Opts = opts(token_reply(id_token(nonce(Login), #{}))),
    {302, Cap} = callback(Login, ok_query(Login), Opts),
    ?assertEqual(<<"/orders?page=2">>, livery_test_adapter:header(<<"location">>, Cap)),
    Cookies = [V || {<<"set-cookie">>, V} <- livery_test_adapter:headers(Cap)],
    [Session] = [C || <<"session=", C/binary>> <- Cookies],
    [Value | _] = binary:split(Session, <<";">>),
    ?assertEqual(
        {ok, #{<<"sub">> => <<"alice">>, <<"iss">> => ?ISS, <<"email">> => <<"alice@example.org">>}},
        livery_auth_session:verify(Value, #{secret => ?SECRET})
    ),
    ?assert(lists:any(fun(C) -> binary:match(C, <<"session_login=; ">>) =/= nomatch end, Cookies)).

open_redirect_refused_test_() ->
    [
        ?_test(begin
            Login = start(iolist_to_binary(uri_string:compose_query([{<<"return_to">>, Target}]))),
            {302, Cap} = callback(
                Login, ok_query(Login), opts(token_reply(id_token(nonce(Login), #{})))
            ),
            ?assertEqual(<<"/">>, livery_test_adapter:header(<<"location">>, Cap))
        end)
     || Target <- [
            <<"//evil.example">>, <<"https://evil.example/">>, <<"/\\evil.example">>, <<"evil">>
        ]
    ].

refusals_test_() ->
    Cases = [
        {"no state cookie", {400, <<"sign-in expired, please start again">>}, fun(L) ->
            {ok_query(L), [], #{}}
        end},
        {"tampered state cookie", {400, <<"sign-in expired, please start again">>}, fun(L) ->
            {ok_query(L), [{<<"cookie">>, <<(maps:get(cookie, L))/binary, "x">>}], #{}}
        end},
        {"wrong state", {400, <<"sign-in state does not match">>}, fun(L) ->
            {
                lists:keyreplace(<<"state">>, 1, ok_query(L), {<<"state">>, <<"other">>}),
                default,
                #{}
            }
        end},
        {"provider error", {401, <<"sign-in refused by the provider: access_denied">>}, fun(L) ->
            {
                [
                    {<<"state">>, maps:get(<<"state">>, maps:get(params, L))},
                    {<<"error">>, <<"access_denied">>}
                ],
                default,
                #{}
            }
        end},
        {"other issuer", {400, <<"sign-in response comes from another issuer">>}, fun(L) ->
            {
                lists:keyreplace(
                    <<"iss">>, 1, ok_query(L), {<<"iss">>, <<"https://evil.example">>}
                ),
                default,
                #{}
            }
        end},
        {"wrong nonce", {401, <<"ID token nonce does not match">>}, fun(_L) ->
            {undefined, default, #{<<"nonce">> => <<"replayed">>}}
        end},
        {"other audience", {401, <<"invalid ID token">>}, fun(_L) ->
            {undefined, default, #{<<"aud">> => <<"another-app">>}}
        end},
        {"several audiences, no azp", {401, <<"ID token is for another client">>}, fun(_L) ->
            {undefined, default, #{<<"aud">> => [?CLIENT, <<"another-app">>]}}
        end},
        {"azp for another client", {401, <<"ID token is for another client">>}, fun(_L) ->
            {undefined, default, #{<<"azp">> => <<"another-app">>}}
        end},
        {"expired", {401, <<"invalid ID token">>}, fun(_L) ->
            {undefined, default, #{<<"exp">> => os:system_time(second) - 600}}
        end},
        {"bad at_hash", {401, <<"ID token at_hash does not match">>}, fun(_L) ->
            {undefined, default, #{<<"at_hash">> => <<"AAAA">>}}
        end}
    ],
    [
        {Name,
            ?_test(begin
                Login = start(<<>>),
                {Query0, Headers0, ClaimOverrides} = Make(Login),
                Query =
                    case Query0 of
                        undefined -> ok_query(Login);
                        Q -> Q
                    end,
                Headers =
                    case Headers0 of
                        default -> [{<<"cookie">>, maps:get(cookie, Login)}];
                        H -> H
                    end,
                IdToken = id_token(nonce(Login), ClaimOverrides),
                {Got, Cap} = callback(Login, Query, opts(token_reply(IdToken)), Headers),
                ?assertEqual(Expected, {Got, livery_test_adapter:body(Cap)})
            end)}
     || {Name, Expected, Make} <- Cases
    ].

%% RFC 9207 2.4: a provider that always sends `iss' must send it.
iss_required_when_advertised_test() ->
    Login = start(<<>>),
    Opts0 = opts(token_reply(id_token(nonce(Login), #{}))),
    Opts = Opts0#{
        provider => (provider())#{<<"authorization_response_iss_parameter_supported">> => true}
    },
    ?assertMatch({400, _}, callback(Login, lists:keydelete(<<"iss">>, 1, ok_query(Login)), Opts)),
    ?assertMatch({302, _}, callback(Login, ok_query(Login), Opts)).

valid_at_hash_test() ->
    Login = start(<<>>),
    Digest = crypto:hash(sha256, <<"at">>),
    AtHash = base64:encode(binary:part(Digest, 0, 16), #{mode => urlsafe, padding => false}),
    Opts = opts(token_reply(id_token(nonce(Login), #{<<"at_hash">> => AtHash}))),
    ?assertMatch({302, _}, callback(Login, ok_query(Login), Opts)).

unsigned_id_token_refused_test() ->
    Login = start(<<>>),
    B64 = fun(B) -> base64:encode(B, #{mode => urlsafe, padding => false}) end,
    Claims = #{
        <<"iss">> => ?ISS, <<"sub">> => <<"a">>, <<"aud">> => ?CLIENT, <<"nonce">> => nonce(Login)
    },
    Unsigned = <<
        (B64(<<"{\"alg\":\"none\"}">>))/binary,
        ".",
        (B64(iolist_to_binary(json:encode(Claims))))/binary,
        "."
    >>,
    ?assertMatch({401, _}, callback(Login, ok_query(Login), opts(token_reply(Unsigned)))).

%%====================================================================
%% Logout and routes
%%====================================================================

logout_clears_session_test() ->
    Cap = livery_test_adapter:run([], livery_auth_login:logout(opts(token_reply(<<>>))), #{}),
    ?assertEqual(302, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"/">>, livery_test_adapter:header(<<"location">>, Cap)),
    ?assertMatch(<<"session=; ", _/binary>>, livery_test_adapter:header(<<"set-cookie">>, Cap)).

routes_test() ->
    Routes = livery_auth_login:routes(opts(token_reply(<<>>))),
    ?assertEqual(
        [
            {<<"GET">>, <<"/login">>},
            {<<"GET">>, <<"/auth/callback">>},
            {<<"GET">>, <<"/logout">>},
            {<<"POST">>, <<"/logout">>}
        ],
        [{M, P} || {M, P, _} <- Routes]
    ).
