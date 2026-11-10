%% @doc Passkey routes end to end: register while signed in, sign in
%% without a username, single-use challenges, cookies.
-module(livery_auth_passkey_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, livery_webauthn_authenticator).
-define(SECRET, <<"a long session secret">>).
-define(ALICE, #{id => <<"user-alice">>, name => <<"alice">>}).

passkey_test_() ->
    {setup,
        fun() ->
            {ok, Apps} = application:ensure_all_started(livery),
            Apps
        end,
        fun(Apps) -> [application:stop(A) || A <- lists:reverse(Apps)] end, [
            {"register then sign in", fun register_and_sign_in/0},
            {"a challenge is used once", fun challenge_used_once/0},
            {"registration needs a signed-in user", fun register_needs_user/0},
            {"unknown passkey", fun unknown_credential/0},
            {"a challenge is tied to its ceremony", fun ceremony_mismatch/0},
            {"no challenge cookie", fun no_challenge/0}
        ]}.

%%====================================================================
%% Fixture: an application with an ETS credential store
%%====================================================================

opts(Tab, User) ->
    #{
        rp_id => <<"example.com">>,
        rp_name => <<"Example">>,
        origins => [<<"https://example.com">>],
        session => #{secret => ?SECRET},
        current_user => fun(_Req) -> User end,
        credentials_for_user => fun(#{id := Id}) ->
            [C || {C, Owner, _} <- ets:tab2list(Tab), Owner =:= Id]
        end,
        store_credential => fun(#{id := Id}, #{id := CredId} = Cred) ->
            true = ets:insert(Tab, {CredId, Id, Cred}),
            ok
        end,
        find_credential => fun(CredId) ->
            case ets:lookup(Tab, CredId) of
                [{_, _Owner, Cred}] -> {ok, ?ALICE, Cred};
                [] -> not_found
            end
        end,
        update_credential => fun(CredId, Updates) ->
            [{_, Owner, Cred}] = ets:lookup(Tab, CredId),
            true = ets:insert(Tab, {CredId, Owner, maps:merge(Cred, Updates)}),
            ok
        end
    }.

route(Opts, Suffix) ->
    [H] = [
        H
     || {_, P, H} <- livery_auth_passkey:routes(Opts), P =:= <<"/passkeys/", Suffix/binary>>
    ],
    H.

%% POST to a route; returns {Status, JsonBody, SetCookies}.
post(Opts, Suffix, Cookies, Body) ->
    Headers = [{<<"cookie">>, iolist_to_binary(lists:join(<<"; ">>, Cookies))} || Cookies =/= []],
    Cap = livery_test_adapter:run([], route(Opts, Suffix), #{
        method => <<"POST">>,
        headers => Headers,
        body => {buffered, iolist_to_binary(json:encode(Body))}
    }),
    SetCookies = [V || {<<"set-cookie">>, V} <- livery_test_adapter:headers(Cap)],
    {livery_test_adapter:status(Cap), json:decode(livery_test_adapter:body(Cap)), SetCookies}.

%% The `name=value' pair of the Set-Cookie for `Name' that sets a value.
cookie(Name, SetCookies) ->
    [Pair] = [
        P
     || C <- SetCookies,
        [P | _] <- [binary:split(C, <<";">>)],
        is_prefix(<<Name/binary, "=">>, P),
        byte_size(P) > byte_size(Name) + 1
    ],
    Pair.

is_prefix(Prefix, Bin) -> binary:longest_common_prefix([Prefix, Bin]) =:= byte_size(Prefix).

challenge(#{<<"challenge">> := C}) ->
    {ok, Raw} = livery_auth_jose:b64url(C),
    Raw.

registered(Tab) ->
    Opts = opts(Tab, ?ALICE),
    Cred = ?A:new(-7),
    {200, Options, Set} = post(Opts, <<"register/options">>, [], #{}),
    Resp = ?A:register(Cred, #{challenge => challenge(Options)}),
    {201, #{<<"id">> := _}, _} = post(
        Opts, <<"register">>, [cookie(<<"session_passkey">>, Set)], Resp
    ),
    {Opts, Cred}.

%%====================================================================
%% Cases
%%====================================================================

register_and_sign_in() ->
    Tab = ets:new(creds, [public]),
    {Opts, Cred} = registered(Tab),
    [{CredId, <<"user-alice">>, Stored}] = ets:tab2list(Tab),
    ?assertEqual(maps:get(id, Cred), CredId),
    ?assertEqual(<<"user-alice">>, maps:get(user_handle, Stored)),
    %% A second registration excludes the passkey already there.
    {200, #{<<"excludeCredentials">> := [#{<<"id">> := Excluded}]}, _} =
        post(Opts, <<"register/options">>, [], #{}),
    ?assertEqual(?A:b64(CredId), Excluded),
    %% Sign in, no username.
    {200, Options, Set} = post(opts(Tab, undefined), <<"login/options">>, [], #{}),
    ?assertEqual([], maps:get(<<"allowCredentials">>, Options)),
    Assertion = ?A:assert(Cred, 1, #{
        challenge => challenge(Options), user_handle => <<"user-alice">>
    }),
    {200, #{<<"ok">> := true}, Out} = post(
        opts(Tab, undefined), <<"login">>, [cookie(<<"session_passkey">>, Set)], Assertion
    ),
    <<"session=", Session/binary>> = cookie(<<"session">>, Out),
    ?assertEqual(
        {ok, #{<<"sub">> => ?A:b64(<<"user-alice">>)}},
        livery_auth_session:verify(Session, #{secret => ?SECRET})
    ),
    ?assert(lists:any(fun(C) -> is_prefix(<<"session_passkey=;">>, C) end, Out)),
    [{_, _, After}] = ets:tab2list(Tab),
    ?assertEqual(1, maps:get(sign_count, After)).

challenge_used_once() ->
    Tab = ets:new(creds, [public]),
    {_Opts, Cred} = registered(Tab),
    Opts = opts(Tab, undefined),
    {200, Options, Set} = post(Opts, <<"login/options">>, [], #{}),
    Cookie = cookie(<<"session_passkey">>, Set),
    Assertion = ?A:assert(Cred, 0, #{challenge => challenge(Options)}),
    {200, _, _} = post(Opts, <<"login">>, [Cookie], Assertion),
    ?assertMatch(
        {400, #{<<"error">> := <<"challenge_reused">>}, _},
        post(Opts, <<"login">>, [Cookie], Assertion)
    ).

register_needs_user() ->
    Opts = opts(ets:new(creds, [public]), undefined),
    ?assertMatch(
        {401, #{<<"error">> := <<"sign_in_first">>}, _}, post(Opts, <<"register/options">>, [], #{})
    ).

unknown_credential() ->
    Tab = ets:new(creds, [public]),
    Opts = opts(Tab, undefined),
    {200, Options, Set} = post(Opts, <<"login/options">>, [], #{}),
    Assertion = ?A:assert(?A:new(-7), 1, #{challenge => challenge(Options)}),
    ?assertMatch(
        {400, #{<<"error">> := <<"unknown_credential">>}, _},
        post(Opts, <<"login">>, [cookie(<<"session_passkey">>, Set)], Assertion)
    ).

%% A registration challenge cannot finish a sign-in.
ceremony_mismatch() ->
    Tab = ets:new(creds, [public]),
    {_, Cred} = registered(Tab),
    {200, Options, Set} = post(opts(Tab, ?ALICE), <<"register/options">>, [], #{}),
    Assertion = ?A:assert(Cred, 1, #{challenge => challenge(Options)}),
    ?assertMatch(
        {400, #{<<"error">> := <<"no_challenge">>}, _},
        post(opts(Tab, undefined), <<"login">>, [cookie(<<"session_passkey">>, Set)], Assertion)
    ).

no_challenge() ->
    Tab = ets:new(creds, [public]),
    {_, Cred} = registered(Tab),
    Assertion = ?A:assert(Cred, 1, #{challenge => crypto:strong_rand_bytes(32)}),
    ?assertMatch(
        {400, #{<<"error">> := <<"no_challenge">>}, _},
        post(opts(Tab, undefined), <<"login">>, [], Assertion)
    ).
