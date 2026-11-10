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

%%====================================================================
%% Logout at the provider (OpenID Connect RP-Initiated Logout 1.0)
%%====================================================================

logout_opts(Extra) ->
    Opts = opts(token_reply(<<>>)),
    maps:merge(
        Opts#{provider => (provider())#{<<"end_session_endpoint">> => <<?ISS/binary, "/logout">>}},
        Extra
    ).

%% Sign in with `keep_id_token' and return the session cookie and the ID
%% token it holds.
signed_in_session() ->
    Login = start(<<>>),
    IdToken = id_token(nonce(Login), #{}),
    {302, Cap} = callback(Login, ok_query(Login), (opts(token_reply(IdToken)))#{
        keep_id_token => true
    }),
    [Session] = [
        C
     || {<<"set-cookie">>, <<"session=", C/binary>>} <- livery_test_adapter:headers(Cap)
    ],
    [Value | _] = binary:split(Session, <<";">>),
    {Value, IdToken}.

logout_location(Opts, Headers) ->
    Cap = livery_test_adapter:run([], livery_auth_login:logout(Opts), #{headers => Headers}),
    ?assertMatch(<<"session=; ", _/binary>>, livery_test_adapter:header(<<"set-cookie">>, Cap)),
    livery_test_adapter:header(<<"location">>, Cap).

provider_logout_with_hint_test() ->
    {Value, IdToken} = signed_in_session(),
    ?assertMatch(
        {ok, #{<<"id_token">> := IdToken}}, livery_auth_session:verify(Value, #{secret => ?SECRET})
    ),
    Location = logout_location(
        logout_opts(#{post_logout_redirect_uri => <<"https://app.example/bye">>}),
        [{<<"cookie">>, <<"session=", Value/binary>>}]
    ),
    #{query := Q} = uri_string:parse(Location),
    ?assertMatch(<<"https://id.example/logout?", _/binary>>, Location),
    ?assertEqual(
        [
            {<<"client_id">>, ?CLIENT},
            {<<"post_logout_redirect_uri">>, <<"https://app.example/bye">>},
            {<<"id_token_hint">>, IdToken}
        ],
        uri_string:dissect_query(Q)
    ).

provider_logout_without_session_test() ->
    Location = logout_location(logout_opts(#{}), []),
    #{query := Q} = uri_string:parse(Location),
    ?assertEqual([{<<"client_id">>, ?CLIENT}], uri_string:dissect_query(Q)).

local_logout_when_asked_test() ->
    ?assertEqual(<<"/">>, logout_location(logout_opts(#{provider_logout => false}), [])).

id_token_not_kept_by_default_test() ->
    Login = start(<<>>),
    {302, Cap} = callback(Login, ok_query(Login), opts(token_reply(id_token(nonce(Login), #{})))),
    [Session] = [
        C
     || {<<"set-cookie">>, <<"session=", C/binary>>} <- livery_test_adapter:headers(Cap)
    ],
    [Value | _] = binary:split(Session, <<";">>),
    {ok, Data} = livery_auth_session:verify(Value, #{secret => ?SECRET}),
    ?assertNot(maps:is_key(<<"id_token">>, Data)).

%%====================================================================
%% Step-up (RFC 9470, OIDC Core 3.1.3.7 step 11)
%%====================================================================

stepup_login(Query, Opts) ->
    Cap = livery_test_adapter:run([], livery_auth_login:login(Opts), #{raw_query => Query}),
    302 = livery_test_adapter:status(Cap),
    #{query := Q} = uri_string:parse(livery_test_adapter:header(<<"location">>, Cap)),
    [Cookie | _] = binary:split(livery_test_adapter:header(<<"set-cookie">>, Cap), <<";">>),
    #{params => maps:from_list(uri_string:dissect_query(Q)), cookie => Cookie}.

stepup_request_test_() ->
    Base = (opts(token_reply(<<>>)))#{step_up_acr_values => [<<"gold">>]},
    [
        {"defaults from the options",
            ?_assertMatch(
                #{<<"acr_values">> := <<"silver">>, <<"max_age">> := <<"600">>},
                maps:get(
                    params, stepup_login(<<>>, Base#{acr_values => [<<"silver">>], max_age => 600})
                )
            )},
        {"allowed query values",
            ?_assertMatch(
                #{<<"acr_values">> := <<"gold">>, <<"max_age">> := <<"0">>},
                maps:get(params, stepup_login(<<"acr_values=gold&max_age=0">>, Base))
            )},
        {"a level not allowed is ignored",
            ?_assertNot(
                maps:is_key(
                    <<"acr_values">>, maps:get(params, stepup_login(<<"acr_values=bronze">>, Base))
                )
            )},
        {"a bad max_age is ignored",
            ?_assertNot(
                maps:is_key(<<"max_age">>, maps:get(params, stepup_login(<<"max_age=soon">>, Base)))
            )}
    ].

stepup_callback_test_() ->
    Now = os:system_time(second),
    Cases = [
        {"level met", <<"acr_values=gold">>, #{<<"acr">> => <<"gold">>}, 302},
        {"other level", <<"acr_values=gold">>, #{<<"acr">> => <<"silver">>}, 401},
        {"no level", <<"acr_values=gold">>, #{}, 401},
        {"recent", <<"max_age=60">>, #{<<"auth_time">> => Now - 5}, 302},
        {"too old", <<"max_age=60">>, #{<<"auth_time">> => Now - 600}, 401},
        {"no auth_time", <<"max_age=60">>, #{}, 401}
    ],
    [
        {Name, fun() ->
            Opts0 = (opts(token_reply(<<>>)))#{step_up_acr_values => [<<"gold">>]},
            Login = stepup_login(Query, Opts0),
            #{params := #{<<"state">> := State, <<"nonce">> := Nonce}, cookie := Cookie} = Login,
            Opts = Opts0#{
                adapter_opts => maps:get(adapter_opts, opts(token_reply(id_token(Nonce, Claims))))
            },
            {Got, _} = callback(
                Login,
                [{<<"state">>, State}, {<<"code">>, <<"c">>}, {<<"iss">>, ?ISS}],
                Opts,
                [{<<"cookie">>, Cookie}]
            ),
            ?assertEqual(Expected, Got)
        end}
     || {Name, Query, Claims, Expected} <- Cases
    ].

session_keeps_acr_and_auth_time_test() ->
    Now = os:system_time(second),
    Login = start(<<>>),
    IdToken = id_token(nonce(Login), #{<<"acr">> => <<"gold">>, <<"auth_time">> => Now}),
    {302, Cap} = callback(Login, ok_query(Login), opts(token_reply(IdToken))),
    [Session] = [
        C
     || {<<"set-cookie">>, <<"session=", C/binary>>} <- livery_test_adapter:headers(Cap)
    ],
    [Value | _] = binary:split(Session, <<";">>),
    ?assertMatch(
        {ok, #{<<"acr">> := <<"gold">>, <<"auth_time">> := Now}},
        livery_auth_session:verify(Value, #{secret => ?SECRET})
    ).

%%====================================================================
%% Pushed authorization requests (RFC 9126)
%%====================================================================

par_endpoint() -> <<?ISS/binary, "/par">>.

par_opts(ProviderExtra, Extra, Reply) ->
    Self = self(),
    Handler = fun(#{url := Url, headers := H} = Req) ->
        {full, Body} = maps:get(body, Req),
        Form = uri_string:dissect_query(iolist_to_binary(Body)),
        Self ! {pushed, Url, H, Form},
        {Status, Json} = Reply,
        {Status, [], iolist_to_binary(json:encode(Json))}
    end,
    maps:merge(
        (opts(token_reply(<<>>)))#{
            provider => maps:merge(
                (provider())#{<<"pushed_authorization_request_endpoint">> => par_endpoint()},
                ProviderExtra
            ),
            adapter_opts => #{handler => Handler}
        },
        Extra
    ).

pushed_ok() ->
    {201, #{
        <<"request_uri">> => <<"urn:ietf:params:oauth:request_uri:abc">>, <<"expires_in">> => 60
    }}.

par_login(Opts) ->
    flush_pushed(),
    livery_test_adapter:run([], livery_auth_login:login(Opts), #{}).

flush_pushed() ->
    receive
        {pushed, _, _, _} -> flush_pushed()
    after 0 -> ok
    end.

par_pushes_the_request_test() ->
    Cap = par_login(par_opts(#{}, #{}, pushed_ok())),
    ?assertEqual(302, livery_test_adapter:status(Cap)),
    #{query := Q} = uri_string:parse(livery_test_adapter:header(<<"location">>, Cap)),
    ?assertEqual(
        [
            {<<"client_id">>, ?CLIENT},
            {<<"request_uri">>, <<"urn:ietf:params:oauth:request_uri:abc">>}
        ],
        uri_string:dissect_query(Q)
    ),
    receive
        {pushed, Url, Headers, Form} ->
            ?assertEqual(par_endpoint(), Url),
            ?assertMatch(<<"Basic ", _/binary>>, proplists:get_value(<<"authorization">>, Headers)),
            [
                ?assert(lists:keymember(K, 1, Form))
             || K <- [
                    <<"client_id">>,
                    <<"response_type">>,
                    <<"redirect_uri">>,
                    <<"state">>,
                    <<"nonce">>,
                    <<"code_challenge">>
                ]
            ],
            ?assertNot(lists:keymember(<<"request_uri">>, 1, Form))
    after 1000 -> error(not_pushed)
    end.

par_not_used_when_disabled_test() ->
    Cap = par_login(par_opts(#{}, #{par => false}, pushed_ok())),
    ?assertMatch(
        <<"https://id.example/authorize?response_type=code", _/binary>>,
        livery_test_adapter:header(<<"location">>, Cap)
    ).

par_used_when_required_even_if_disabled_test() ->
    Cap = par_login(
        par_opts(
            #{<<"require_pushed_authorization_requests">> => true}, #{par => false}, pushed_ok()
        )
    ),
    ?assertMatch(
        <<"https://id.example/authorize?client_id=", _/binary>>,
        livery_test_adapter:header(<<"location">>, Cap)
    ).

par_not_used_without_endpoint_test() ->
    Opts = maps:remove(par, par_opts(#{}, #{}, pushed_ok())),
    NoPar = Opts#{provider => provider()},
    Cap = par_login(NoPar),
    ?assertMatch(
        <<"https://id.example/authorize?response_type=code", _/binary>>,
        livery_test_adapter:header(<<"location">>, Cap)
    ).

par_failure_is_502_test() ->
    Cap = par_login(par_opts(#{}, #{}, {400, #{<<"error">> => <<"invalid_request">>}})),
    ?assertEqual(502, livery_test_adapter:status(Cap)),
    ?assertEqual(undefined, livery_test_adapter:header(<<"set-cookie">>, Cap)).

%% RFC 9126 2 with RFC 10070: an assertion sent to the PAR endpoint names
%% the issuer as its audience.
par_with_private_key_jwt_test() ->
    {Key, Jwk} = livery_auth_jwt:keypair(<<"ES256">>, <<"k">>),
    Opts = maps:remove(
        client_secret,
        par_opts(#{}, #{client_auth => private_key_jwt, private_key => Key}, pushed_ok())
    ),
    302 = livery_test_adapter:status(par_login(Opts)),
    receive
        {pushed, _, Headers, Form} ->
            ?assertEqual(undefined, proplists:get_value(<<"authorization">>, Headers)),
            {ok, Claims} = livery_auth:verify(proplists:get_value(<<"client_assertion">>, Form), #{
                keys => [Jwk]
            }),
            ?assertEqual(?ISS, maps:get(<<"aud">>, Claims))
    after 1000 -> error(not_pushed)
    end.

%% The sign-in state cookie cannot stand in for a session cookie.
state_cookie_is_not_a_session_test() ->
    #{cookie := Cookie} = start(<<>>),
    [_Name, Value] = binary:split(Cookie, <<"=">>),
    Stack = [{livery_auth_session, #{secret => ?SECRET, required => true}}],
    Cap = livery_test_adapter:run(
        Stack,
        fun(_) -> livery_resp:text(200, <<"in">>) end,
        #{headers => [{<<"cookie">>, <<"session=", Value/binary>>}]}
    ),
    ?assertEqual(401, livery_test_adapter:status(Cap)).
