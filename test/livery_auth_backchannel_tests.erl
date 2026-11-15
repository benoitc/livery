%% @doc OpenID Connect Back-Channel Logout 1.0: logout token checks
%% (sections 2.4 and 2.6), the sessions ended (2.7) and the answer (2.8).
-module(livery_auth_backchannel_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ISS, <<"https://id.example">>).
-define(CLIENT, <<"my-app">>).
-define(SECRET, <<"a long session secret">>).
-define(EVENT, <<"http://schemas.openid.net/event/backchannel-logout">>).
-define(PATH, <<"/auth/backchannel-logout">>).

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

session() ->
    #{secret => ?SECRET, max_age => 600, store => livery_auth_session_ets}.

opts() ->
    opts(#{}).

opts(Extra) ->
    {_Key, Jwk} = issuer_key(),
    maps:merge(
        #{
            provider => provider(),
            client_id => ?CLIENT,
            redirect_uri => <<"https://app.example/auth/callback">>,
            session => session(),
            keys => [Jwk],
            backchannel_logout_path => ?PATH
        },
        Extra
    ).

claims(Overrides) ->
    Now = os:system_time(second),
    maps:filter(
        fun(_K, V) -> V =/= drop end,
        maps:merge(
            #{
                <<"iss">> => ?ISS,
                <<"aud">> => ?CLIENT,
                <<"iat">> => Now,
                <<"exp">> => Now + 120,
                <<"jti">> => base64:encode(crypto:strong_rand_bytes(12)),
                <<"events">> => #{?EVENT => #{}},
                <<"sid">> => <<"op-session">>
            },
            Overrides
        )
    ).

token(Overrides) ->
    token(Overrides, #{}).

token(Overrides, Header) ->
    {{Alg, _} = Key, _} = issuer_key(),
    livery_auth_jwt:mint_raw(
        Key, maps:merge(#{<<"alg">> => Alg, <<"kid">> => <<"id-key">>}, Header), claims(Overrides)
    ).

b64(B) -> base64:encode(B, #{mode => urlsafe, padding => false}).

unsigned(Claims) ->
    <<
        (b64(<<"{\"alg\":\"none\"}">>))/binary,
        ".",
        (b64(iolist_to_binary(json:encode(Claims))))/binary,
        "."
    >>.

hs256(Claims) ->
    H = b64(<<"{\"alg\":\"HS256\",\"kid\":\"id-key\"}">>),
    P = b64(iolist_to_binary(json:encode(Claims))),
    S = b64(crypto:mac(hmac, sha256, <<"guess">>, <<H/binary, ".", P/binary>>)),
    <<H/binary, ".", P/binary, ".", S/binary>>.

%% POST a form to the route, through its middleware stack.
post(Body) ->
    post(Body, opts()).

post(Body, Opts) ->
    [{_, _, Handler, #{middleware := Stack}}] = [
        R
     || {<<"POST">>, P, _, _} = R <- livery_auth_login:routes(Opts), P =:= ?PATH
    ],
    livery_test_adapter:run(Stack, Handler, #{
        method => <<"POST">>,
        path => ?PATH,
        headers => [{<<"content-type">>, <<"application/x-www-form-urlencoded">>}],
        body => {buffered, Body}
    }).

form(Token) ->
    iolist_to_binary(uri_string:compose_query([{<<"logout_token">>, Token}])).

open(Sub, PSid) ->
    {ok, Value} = livery_auth_session:create(
        #{}, #{iss => ?ISS, sub => Sub, provider_sid => PSid}, session()
    ),
    {ok, #{<<"livery_sid">> := Sid}} = livery_auth_session:verify(Value, session()),
    Sid.

live(Sid) -> livery_auth_session_ets:check(undefined, Sid).

%%====================================================================
%% Cases
%%====================================================================

backchannel_test_() ->
    {setup,
        fun() ->
            {ok, Apps} = application:ensure_all_started(livery),
            Apps
        end,
        fun(Apps) -> [application:stop(A) || A <- lists:reverse(Apps)] end, [
            {"accepted tokens", fun accepted/0},
            {"refused tokens", fun refused/0},
            {"sid required", fun sid_required/0},
            {"typ required when asked", fun require_typ/0},
            {"a token is used once", fun replay/0},
            {"a sid ends that provider session only", fun ends_provider_session/0},
            {"a sub ends every session of the user", fun ends_user_sessions/0},
            {"on_logout is told", fun on_logout_called/0},
            {"200 with no-store", fun answer_ok/0},
            {"400 with the error body and no-store", fun answer_refused/0},
            {"on_logout raising is a 400", fun on_logout_raises/0},
            {"no logout_token is a 400", fun no_token/0},
            {"a large body is refused", fun body_limit/0}
        ]}.

accepted() ->
    Ok = fun(T) -> ?assertMatch({ok, _}, livery_auth_backchannel:verify(T, opts())) end,
    Ok(token(#{})),
    Ok(token(#{<<"sid">> => drop, <<"sub">> => <<"alice">>})),
    Ok(token(#{<<"sub">> => <<"alice">>})),
    Ok(token(#{}, #{<<"typ">> => <<"logout+jwt">>})),
    Ok(token(#{}, #{<<"typ">> => <<"application/logout+jwt">>})),
    %% Typing is only recommended (2.4, 4.1), so other values pass by default.
    Ok(token(#{}, #{<<"typ">> => <<"JWT">>})),
    ?assertEqual(
        {ok, #{iss => ?ISS, sub => <<"alice">>, sid => undefined}},
        livery_auth_backchannel:verify(
            token(#{<<"sid">> => drop, <<"sub">> => <<"alice">>}), opts()
        )
    ).

refused() ->
    Now = os:system_time(second),
    {OtherKey, _} = livery_auth_jwt:keypair(<<"RS256">>, <<"id-key">>),
    Cases = [
        {"wrong key",
            livery_auth_jwt:mint_raw(
                OtherKey, #{<<"alg">> => <<"RS256">>, <<"kid">> => <<"id-key">>}, claims(#{})
            ),
            bad_signature},
        {"alg none", unsigned(claims(#{})), {unsupported_alg, <<"none">>}},
        {"HS256", hs256(claims(#{})), {unsupported_alg, <<"HS256">>}},
        {"wrong iss", token(#{<<"iss">> => <<"https://evil.example">>}), {issuer_mismatch, ?ISS}},
        {"wrong aud", token(#{<<"aud">> => <<"other-app">>}), audience_mismatch},
        {"no exp", token(#{<<"exp">> => drop}), {missing_claim, <<"exp">>}},
        {"no iat", token(#{<<"iat">> => drop}), {missing_claim, <<"iat">>}},
        {"no jti", token(#{<<"jti">> => drop}), {missing_claim, <<"jti">>}},
        {"no events", token(#{<<"events">> => drop}), {missing_claim, <<"events">>}},
        {"expired", token(#{<<"iat">> => Now - 200, <<"exp">> => Now - 10}), expired},
        {"exp not a number", token(#{<<"exp">> => <<"soon">>}), {invalid_claim, <<"exp">>}},
        {"iat in the future", token(#{<<"iat">> => Now + 60}), issued_in_future},
        {"iat too old", token(#{<<"iat">> => Now - 400, <<"exp">> => Now + 60}), too_old},
        {"event missing", token(#{<<"events">> => #{<<"other">> => #{}}}), no_logout_event},
        {"event not an object", token(#{<<"events">> => #{?EVENT => true}}), no_logout_event},
        {"neither sub nor sid", token(#{<<"sid">> => drop}), no_subject},
        {"nonce present", token(#{<<"nonce">> => <<"n">>}), nonce_present},
        {"five parts", <<"a.b.c.d.e">>, malformed}
    ],
    [
        ?assertEqual({Name, {error, Why}}, {Name, livery_auth_backchannel:verify(T, opts())})
     || {Name, T, Why} <- Cases
    ].

require_typ() ->
    Opts = opts(#{backchannel_require_typ => true}),
    V = fun(T) -> livery_auth_backchannel:verify(T, Opts) end,
    ?assertMatch({ok, _}, V(token(#{}, #{<<"typ">> => <<"logout+jwt">>}))),
    ?assertMatch({ok, _}, V(token(#{}, #{<<"typ">> => <<"application/Logout+JWT">>}))),
    ?assertEqual({error, {invalid_typ, <<"JWT">>}}, V(token(#{}, #{<<"typ">> => <<"JWT">>}))),
    ?assertEqual({error, {invalid_typ, undefined}}, V(token(#{}))).

sid_required() ->
    Opts = opts(#{backchannel_session_required => true}),
    ?assertEqual(
        {error, sid_required},
        livery_auth_backchannel:verify(
            token(#{<<"sid">> => drop, <<"sub">> => <<"alice">>}), Opts
        )
    ),
    ?assertMatch({ok, _}, livery_auth_backchannel:verify(token(#{}), Opts)).

replay() ->
    T = token(#{}),
    ?assertMatch({ok, _}, livery_auth_backchannel:verify(T, opts())),
    ?assertEqual({error, replayed}, livery_auth_backchannel:verify(T, opts())).

ends_provider_session() ->
    Mine = open(<<"bob">>, <<"op-1">>),
    Other = open(<<"bob">>, <<"op-2">>),
    ?assertEqual(200, livery_test_adapter:status(post(form(token(#{<<"sid">> => <<"op-1">>}))))),
    ?assertEqual({invalid, valid}, {live(Mine), live(Other)}).

ends_user_sessions() ->
    A = open(<<"carol">>, <<"op-3">>),
    B = open(<<"carol">>, <<"op-4">>),
    Other = open(<<"dave">>, <<"op-5">>),
    Token = token(#{<<"sid">> => drop, <<"sub">> => <<"carol">>}),
    ?assertEqual(200, livery_test_adapter:status(post(form(Token)))),
    ?assertEqual([invalid, invalid, valid], [live(S) || S <- [A, B, Other]]).

on_logout_called() ->
    Self = self(),
    Opts = opts(#{on_logout => fun(Iss, Sub, Sid) -> Self ! {logged_out, Iss, Sub, Sid} end}),
    Token = token(#{<<"sub">> => <<"erin">>, <<"sid">> => <<"op-6">>}),
    ?assertEqual(200, livery_test_adapter:status(post(form(Token), Opts))),
    receive
        Msg -> ?assertEqual({logged_out, ?ISS, <<"erin">>, <<"op-6">>}, Msg)
    after 1000 -> ?assert(false)
    end.

answer_ok() ->
    Cap = post(form(token(#{}))),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"no-store">>, livery_test_adapter:header(<<"cache-control">>, Cap)).

answer_refused() ->
    Cap = post(form(token(#{<<"nonce">> => <<"n">>}))),
    ?assertEqual(400, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"no-store">>, livery_test_adapter:header(<<"cache-control">>, Cap)),
    ?assertMatch(
        #{<<"error">> := <<"invalid_request">>, <<"error_description">> := _},
        json:decode(livery_test_adapter:body(Cap))
    ).

on_logout_raises() ->
    Opts = opts(#{on_logout => fun(_, _, _) -> error(boom) end}),
    ?assertEqual(400, livery_test_adapter:status(post(form(token(#{})), Opts))).

no_token() ->
    ?assertEqual(400, livery_test_adapter:status(post(<<"state=x">>))).

body_limit() ->
    Big = form(binary:copy(<<"a">>, 20000)),
    ?assertEqual(413, livery_test_adapter:status(post(Big))).

%%====================================================================
%% routes/1
%%====================================================================

route_only_when_asked_test() ->
    Paths = fun(Opts) -> [P || {<<"POST">>, P, _, _} <- livery_auth_login:routes(Opts)] end,
    ?assertEqual([?PATH], Paths(opts())),
    ?assertEqual([], Paths(maps:remove(backchannel_logout_path, opts()))).

route_needs_store_or_on_logout_test() ->
    NoStore = (opts())#{session => #{secret => ?SECRET}},
    ?assertError({missing_option, store_or_on_logout}, livery_auth_login:routes(NoStore)),
    ?assertMatch([_ | _], livery_auth_login:routes(NoStore#{on_logout => fun(_, _, _) -> ok end})).
