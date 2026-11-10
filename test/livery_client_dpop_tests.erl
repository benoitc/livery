%% @doc DPoP on the client side (RFC 9449): proofs at the token endpoint
%% and on API requests, checked by Livery's own resource server code,
%% nonces, bearer fallback.
-module(livery_client_dpop_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TOKEN_URL, <<"https://as.example/token">>).
-define(API, <<"https://api.example">>).
-define(NONCE, #{dpop_nonce => #{secret => <<"nonce secret">>}}).

dpop_test_() ->
    {setup,
        fun() ->
            {ok, Apps} = application:ensure_all_started(livery),
            Apps
        end,
        fun(Apps) -> [application:stop(A) || A <- lists:reverse(Apps)] end, [
            {"token request and API request carry proofs", fun proofs/0},
            {"htu leaves out the query", fun htu_without_query/0},
            {"API nonce: one retry, then reused", fun api_nonce/0},
            {"token endpoint nonce: one retry", fun token_nonce/0},
            {"token endpoint nonce: not retried twice", fun token_nonce_once/0},
            {"bearer answer used as bearer", fun bearer_fallback/0},
            {"bearer answer refused with require", fun bearer_refused/0},
            {"a nonce stays with its origin", fun nonce_per_origin/0},
            {"a generated key outlives the client", fun key_shared/0},
            {"a given key is used", fun given_key/0}
        ]}.

jwk_test_() ->
    [
        {atom_to_list(Name), fun() -> public_jwk(Alg, Gen) end}
     || {Name, Alg, Gen} <- [
            {es256, <<"ES256">>, {namedCurve, secp256r1}},
            {es384, <<"ES384">>, {namedCurve, secp384r1}},
            {ed25519, <<"Ed25519">>, {namedCurve, ed25519}},
            {rs256, <<"RS256">>, {rsa, 2048, 65537}}
        ]
    ].

%%====================================================================
%% Fixture: an authorization server and an API, both in a fun adapter
%%====================================================================

%% `Cfg': `token_type' (default DPoP), `as_nonce' (the AS wants a nonce),
%% `api' (the API handler), `dpop' and other oauth options.
client(Log, Cfg) ->
    Handler = fun(#{url := Url} = Req) ->
        Log ! {sent, Url, Req},
        case Url of
            ?TOKEN_URL -> token_endpoint(Req, Cfg);
            _ -> (maps:get(api, Cfg, fun verifying_api/1))(Req)
        end
    end,
    AdapterOpts = #{handler => Handler},
    OAuth = maps:merge(
        #{
            token_endpoint => ?TOKEN_URL,
            client_id => integer_to_binary(erlang:unique_integer([positive])),
            client_secret => <<"s">>,
            allowed_origins => [?API],
            dpop => true,
            adapter => livery_client_fun_adapter,
            adapter_opts => AdapterOpts
        },
        maps:without([token_type, as_nonce, api, stack], Cfg)
    ),
    livery_client:new(#{
        adapter => livery_client_fun_adapter,
        adapter_opts => AdapterOpts,
        base_url => ?API,
        stack => [livery_client:oauth(OAuth) | maps:get(stack, Cfg, [])]
    }).

token_endpoint(Req, Cfg) ->
    Claims = claims(livery_client:header(<<"dpop">>, Req)),
    case maps:get(as_nonce, Cfg, false) andalso not maps:is_key(<<"nonce">>, Claims) of
        true ->
            {400, [{<<"DPoP-Nonce">>, <<"as-nonce">>}],
                iolist_to_binary(json:encode(#{<<"error">> => <<"use_dpop_nonce">>}))};
        false ->
            Token = #{
                <<"access_token">> =>
                    <<"at-", (base64:encode(crypto:strong_rand_bytes(6)))/binary>>,
                <<"token_type">> => maps:get(token_type, Cfg, <<"DPoP">>),
                <<"expires_in">> => 3600
            },
            {200, [], iolist_to_binary(json:encode(Token))}
    end.

%% Checks the proof the way a Livery resource server does, and echoes
%% the thumbprint.
verifying_api(Req) -> verifying_api(Req, #{}).

verifying_api(Req, Opts) ->
    <<"DPoP ", Token/binary>> = livery_client:header(<<"authorization">>, Req),
    case livery_auth_dpop:verify_proof(server_req(Req), Token, Opts) of
        {ok, Jkt} ->
            {200, [], Jkt};
        {error, use_dpop_nonce} ->
            {401,
                [
                    {<<"www-authenticate">>, <<"DPoP error=\"use_dpop_nonce\"">>},
                    {<<"dpop-nonce">>, livery_auth_dpop:nonce(Opts)}
                ],
                <<>>};
        {error, Reason} ->
            {400, [], iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

server_req(#{url := Url, method := Method, headers := Headers}) ->
    #{scheme := Scheme, host := Host} = Parts = uri_string:parse(Url),
    Authority =
        case maps:find(port, Parts) of
            {ok, Port} -> <<Host/binary, ":", (integer_to_binary(Port))/binary>>;
            error -> Host
        end,
    livery_req:new(#{
        method => string:uppercase(atom_to_binary(Method)),
        scheme => Scheme,
        authority => Authority,
        path => maps:get(path, Parts),
        headers => Headers
    }).

claims(Proof) ->
    [_, P, _] = binary:split(Proof, <<".">>, [global]),
    {ok, Claims} = livery_auth_jose:decode_json(P),
    Claims.

header(Proof) ->
    [H | _] = binary:split(Proof, <<".">>),
    {ok, Header} = livery_auth_jose:decode_json(H),
    Header.

%% Requests the adapter saw, oldest first.
sent() -> sent([]).

sent(Acc) ->
    receive
        {sent, Url, Req} -> sent([{Url, Req} | Acc])
    after 0 -> lists:reverse(Acc)
    end.

to(Url, Sent) -> [R || {U, R} <- Sent, U =:= Url].

body(Resp) ->
    {full, B} = livery_client:body(Resp),
    iolist_to_binary(B).

%%====================================================================
%% Cases
%%====================================================================

proofs() ->
    Client = client(self(), #{}),
    {ok, R1} = livery_client:get(Client, <<"/orders">>),
    {ok, R2} = livery_client:get(Client, <<"/orders">>),
    ?assertEqual(200, livery_client:status(R1)),
    ?assertEqual(body(R1), body(R2)),
    Sent = sent(),
    [TokenReq] = to(?TOKEN_URL, Sent),
    TokenProof = livery_client:header(<<"dpop">>, TokenReq),
    TokenClaims = claims(TokenProof),
    ?assertEqual(<<"POST">>, maps:get(<<"htm">>, TokenClaims)),
    ?assertEqual(?TOKEN_URL, maps:get(<<"htu">>, TokenClaims)),
    ?assertNot(maps:is_key(<<"ath">>, TokenClaims)),
    #{<<"typ">> := <<"dpop+jwt">>, <<"jwk">> := Jwk} = header(TokenProof),
    %% The key the token is bound to signs the API proofs.
    ?assertEqual(livery_auth_dpop:thumbprint(Jwk), body(R1)),
    [A1, A2] = to(<<?API/binary, "/orders">>, Sent),
    ?assertNotEqual(
        livery_client:header(<<"dpop">>, A1), livery_client:header(<<"dpop">>, A2)
    ).

htu_without_query() ->
    Client = client(self(), #{}),
    {ok, R} = livery_client:get(Client, <<"/orders?page=2">>),
    ?assertEqual(200, livery_client:status(R)),
    [ApiReq] = to(<<?API/binary, "/orders?page=2">>, sent()),
    ?assertEqual(
        <<?API/binary, "/orders">>,
        maps:get(<<"htu">>, claims(livery_client:header(<<"dpop">>, ApiReq)))
    ).

api_nonce() ->
    Client = client(self(), #{api => fun(Req) -> verifying_api(Req, ?NONCE) end}),
    {ok, R1} = livery_client:get(Client, <<"/orders">>),
    ?assertEqual(200, livery_client:status(R1)),
    ?assertEqual(2, length(to(<<?API/binary, "/orders">>, sent()))),
    %% The nonce is kept for the next request.
    {ok, R2} = livery_client:get(Client, <<"/orders">>),
    ?assertEqual(200, livery_client:status(R2)),
    ?assertEqual(1, length(to(<<?API/binary, "/orders">>, sent()))).

token_nonce() ->
    Client = client(self(), #{as_nonce => true}),
    {ok, R} = livery_client:get(Client, <<"/orders">>),
    ?assertEqual(200, livery_client:status(R)),
    [First, Second] = to(?TOKEN_URL, sent()),
    ?assertNot(maps:is_key(<<"nonce">>, claims(livery_client:header(<<"dpop">>, First)))),
    ?assertEqual(
        <<"as-nonce">>, maps:get(<<"nonce">>, claims(livery_client:header(<<"dpop">>, Second)))
    ).

%% A server that keeps asking gets its error back after one retry.
token_nonce_once() ->
    Handler = fun(_) ->
        {400, [{<<"dpop-nonce">>, <<"n">>}],
            iolist_to_binary(json:encode(#{<<"error">> => <<"use_dpop_nonce">>}))}
    end,
    Ctx = livery_client_dpop:new(make_ref(), #{}),
    Self = self(),
    Count = fun(Req) ->
        Self ! sent,
        Handler(Req)
    end,
    ?assertEqual(
        {error, {oauth_error, <<"use_dpop_nonce">>, undefined}},
        livery_auth_token:request(client_credentials, #{}, #{
            token_endpoint => ?TOKEN_URL,
            client_id => <<"c">>,
            client_auth => none,
            dpop => Ctx,
            adapter => livery_client_fun_adapter,
            adapter_opts => #{handler => Count}
        })
    ),
    ?assertEqual(2, length([x || _ <- flush(sent)])).

flush(Msg) ->
    receive
        Msg -> [Msg | flush(Msg)]
    after 0 -> []
    end.

bearer_fallback() ->
    Echo = fun(Req) ->
        {200, [], iolist_to_binary(io_lib:format("~p", [livery_client:header(<<"dpop">>, Req)]))}
    end,
    Client = client(self(), #{token_type => <<"Bearer">>, api => Echo}),
    {ok, R} = livery_client:get(Client, <<"/orders">>),
    ?assertEqual(<<"undefined">>, body(R)),
    [ApiReq] = to(<<?API/binary, "/orders">>, sent()),
    ?assertMatch(<<"Bearer ", _/binary>>, livery_client:header(<<"authorization">>, ApiReq)).

bearer_refused() ->
    Client = client(self(), #{token_type => <<"Bearer">>, dpop => #{require => true}}),
    ?assertEqual(
        {error, {unsupported_token_type, <<"Bearer">>}}, livery_client:get(Client, <<"/orders">>)
    ),
    ?assertEqual([], to(<<?API/binary, "/orders">>, sent())).

%% A nonce from one origin is not sent to another; the proof follows a
%% URL a later layer rewrote.
nonce_per_origin() ->
    Other = <<"https://api2.example">>,
    Api = fun(#{url := Url} = Req) ->
        case Url of
            <<"https://api.example", _/binary>> -> {200, [{<<"dpop-nonce">>, <<"from-a">>}], <<>>};
            _ -> verifying_api(Req)
        end
    end,
    ToOther = fun
        (#{url := <<"https://api.example/b">>} = Req, Next) ->
            Next(Req#{url => <<Other/binary, "/b">>});
        (Req, Next) ->
            Next(Req)
    end,
    Client = client(self(), #{
        api => Api, allowed_origins => [?API, Other], stack => [ToOther]
    }),
    {ok, _} = livery_client:get(Client, <<"/a">>),
    {ok, _} = livery_client:get(Client, <<"/a">>),
    {ok, R} = livery_client:get(Client, <<"/b">>),
    ?assertEqual(200, livery_client:status(R)),
    Sent = sent(),
    [_, SecondA] = to(<<?API/binary, "/a">>, Sent),
    ?assertEqual(
        <<"from-a">>, maps:get(<<"nonce">>, claims(livery_client:header(<<"dpop">>, SecondA)))
    ),
    [B] = to(<<Other/binary, "/b">>, Sent),
    BClaims = claims(livery_client:header(<<"dpop">>, B)),
    ?assertEqual(<<Other/binary, "/b">>, maps:get(<<"htu">>, BClaims)),
    ?assertNot(maps:is_key(<<"nonce">>, BClaims)).

%% Building the client again keeps the key, so the cached token is reused.
key_shared() ->
    Id = integer_to_binary(erlang:unique_integer([positive])),
    {ok, R1} = livery_client:get(client(self(), #{client_id => Id}), <<"/orders">>),
    {ok, R2} = livery_client:get(client(self(), #{client_id => Id}), <<"/orders">>),
    ?assertEqual(body(R1), body(R2)),
    ?assertEqual(1, length(to(?TOKEN_URL, sent()))).

given_key() ->
    Key = {<<"Ed25519">>, public_key:generate_key({namedCurve, ed25519})},
    Client = client(self(), #{dpop => #{key => Key}}),
    {ok, R} = livery_client:get(Client, <<"/orders">>),
    ?assertEqual(
        livery_auth_dpop:thumbprint(livery_auth_jose:public_jwk(Key)), body(R)
    ),
    _ = sent().

public_jwk(Alg, Gen) ->
    Key = {Alg, public_key:generate_key(Gen)},
    Jwk = livery_auth_jose:public_jwk(Key),
    ?assertEqual([], [
        M
     || M <- [<<"d">>, <<"p">>, <<"q">>, <<"dp">>, <<"dq">>, <<"qi">>], maps:is_key(M, Jwk)
    ]),
    ?assert(is_binary(livery_auth_dpop:thumbprint(Jwk))),
    [H, P, S] = binary:split(livery_auth_jose:sign(Key, #{}, #{<<"a">> => 1}), <<".">>, [global]),
    {ok, Sig} = livery_auth_jose:b64url(S),
    ?assertEqual(
        ok, livery_auth_jose:verify(Alg, undefined, <<H/binary, ".", P/binary>>, Sig, [Jwk], [Alg])
    ).
