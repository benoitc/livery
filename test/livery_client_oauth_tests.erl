%% @doc Client-credentials layer (RFC 6749 4.4): caching, single fetch
%% under load, refresh before expiry, retry after a revoked token.
-module(livery_client_oauth_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TOKEN_URL, <<"https://as.example/token">>).

oauth_test_() ->
    {setup,
        fun() ->
            {ok, Apps} = application:ensure_all_started(livery),
            Apps
        end,
        fun(Apps) -> [application:stop(A) || A <- lists:reverse(Apps)] end, [
            {"one fetch for many requests", fun cached/0},
            {"one fetch for a concurrent burst", fun single_flight/0},
            {"refresh before expiry", fun skew/0},
            {"retry once after a revoked token", fun revoked/0},
            {"no retry for a streamed body", fun streamed_not_retried/0},
            {"refuse a non-bearer token", fun dpop_token_type/0},
            {"token error is returned", fun token_error/0},
            {"token only for allowed origins", fun origins/0},
            {"origins from the resource", fun resource_origins/0},
            {"origins are required", fun origins_required/0},
            {"a rewrite after the layer cannot leak", fun rewritten_after/0}
        ]}.

%% A client whose token endpoint and API are both answered by `Api',
%% counting token fetches in `Counter'. Each client gets its own id, so
%% tests do not share cached tokens.
client(Counter, TokenReply, Api) -> client(Counter, TokenReply, Api, #{}).

client(Counter, TokenReply, Api, Extra) ->
    Handler = fun(#{url := Url} = Req) ->
        case Url of
            ?TOKEN_URL ->
                N = counters:get(Counter, 1) + 1,
                counters:add(Counter, 1, 1),
                {200, [], iolist_to_binary(json:encode(TokenReply(N)))};
            _ ->
                Api(Req)
        end
    end,
    AdapterOpts = #{handler => Handler},
    OAuth = maps:merge(
        #{
            token_endpoint => ?TOKEN_URL,
            client_id => integer_to_binary(erlang:unique_integer([positive])),
            client_secret => <<"s">>,
            allowed_origins => [<<"https://api.example">>],
            adapter => livery_client_fun_adapter,
            adapter_opts => AdapterOpts
        },
        Extra
    ),
    livery_client:new(#{
        adapter => livery_client_fun_adapter,
        adapter_opts => AdapterOpts,
        base_url => <<"https://api.example">>,
        stack => [livery_client:oauth(OAuth)]
    }).

token(N) -> token(N, 3600).

token(N, ExpiresIn) ->
    #{
        <<"access_token">> => <<"t", (integer_to_binary(N))/binary>>,
        <<"token_type">> => <<"Bearer">>,
        <<"expires_in">> => ExpiresIn
    }.

echo_auth(Req) ->
    {200, [], livery_client:header(<<"authorization">>, Req)}.

body(Resp) ->
    {full, B} = livery_client:body(Resp),
    B.

cached() ->
    C = counters:new(1, []),
    Client = client(C, fun token/1, fun echo_auth/1),
    Bodies = [
        begin
            {ok, R} = livery_client:get(Client, <<"/x">>),
            body(R)
        end
     || _ <- lists:seq(1, 5)
    ],
    ?assertEqual(lists:duplicate(5, <<"Bearer t1">>), Bodies),
    ?assertEqual(1, counters:get(C, 1)).

single_flight() ->
    C = counters:new(1, []),
    Slow = fun(N) ->
        timer:sleep(100),
        token(N)
    end,
    Client = client(C, Slow, fun echo_auth/1),
    Self = self(),
    _ = [
        spawn(fun() -> Self ! {done, livery_client:get(Client, <<"/x">>)} end)
     || _ <- lists:seq(1, 50)
    ],
    Results = [
        receive
            {done, R} -> R
        after 5000 -> error(timeout)
        end
     || _ <- lists:seq(1, 50)
    ],
    ?assert(lists:all(fun({ok, R}) -> body(R) =:= <<"Bearer t1">> end, Results)),
    ?assertEqual(1, counters:get(C, 1)).

%% A token that expires within the skew is not reused.
skew() ->
    C = counters:new(1, []),
    Client = client(C, fun(N) -> token(N, 20) end, fun echo_auth/1, #{refresh_skew => 30}),
    {ok, _} = livery_client:get(Client, <<"/x">>),
    {ok, R} = livery_client:get(Client, <<"/x">>),
    ?assertEqual(<<"Bearer t2">>, body(R)),
    ?assertEqual(2, counters:get(C, 1)).

revoked_api(Req) ->
    case livery_client:header(<<"authorization">>, Req) of
        <<"Bearer t1">> ->
            {401, [{<<"www-authenticate">>, <<"Bearer error=\"invalid_token\"">>}], <<>>};
        Other ->
            {200, [], Other}
    end.

revoked() ->
    C = counters:new(1, []),
    Client = client(C, fun token/1, fun revoked_api/1),
    {ok, R} = livery_client:get(Client, <<"/x">>),
    ?assertEqual(200, livery_client:status(R)),
    ?assertEqual(<<"Bearer t2">>, body(R)),
    ?assertEqual(2, counters:get(C, 1)).

streamed_not_retried() ->
    C = counters:new(1, []),
    Client = client(C, fun token/1, fun revoked_api/1),
    Producer = fun() -> eof end,
    {ok, R} = livery_client:request(Client, post, <<"/x">>, #{body => {stream, Producer}}),
    ?assertEqual(401, livery_client:status(R)),
    ?assertEqual(1, counters:get(C, 1)).

dpop_token_type() ->
    C = counters:new(1, []),
    Client = client(C, fun(N) -> (token(N))#{<<"token_type">> => <<"DPoP">>} end, fun echo_auth/1),
    ?assertEqual(
        {error, {unsupported_token_type, <<"DPoP">>}}, livery_client:get(Client, <<"/x">>)
    ).

token_error() ->
    Handler = fun(_) ->
        {400, [], iolist_to_binary(json:encode(#{<<"error">> => <<"invalid_scope">>}))}
    end,
    Client = livery_client:new(#{
        adapter => livery_client_fun_adapter,
        adapter_opts => #{handler => Handler},
        stack => [
            livery_client:oauth(#{
                token_endpoint => ?TOKEN_URL,
                client_id => <<"err">>,
                client_secret => <<"s">>,
                allowed_origins => [<<"https://api.example">>],
                adapter => livery_client_fun_adapter,
                adapter_opts => #{handler => Handler}
            })
        ]
    }),
    ?assertEqual(
        {error, {oauth_error, <<"invalid_scope">>, undefined}},
        livery_client:get(Client, <<"https://api.example/x">>)
    ).

%% Where the token may go (RFC 8707 resources, or explicit origins).
sent_to(Counter) ->
    fun(#{url := Url} = Req) ->
        counters:add(Counter, 1, 1),
        {200, [], iolist_to_binary([Url, " ", livery_client:header(<<"authorization">>, Req)])}
    end.

origins() ->
    C = counters:new(1, []),
    Api = counters:new(1, []),
    %% No base URL, so requests go to the absolute URL they name.
    Client = (client(C, fun token/1, sent_to(Api)))#{base_url => <<>>},
    {ok, R} = livery_client:get(Client, <<"https://api.example/x">>),
    ?assertEqual(<<"https://api.example/x Bearer t1">>, body(R)),
    {ok, R2} = livery_client:get(Client, <<"HTTPS://API.EXAMPLE:443/y">>),
    ?assertEqual(<<"HTTPS://API.EXAMPLE:443/y Bearer t1">>, body(R2)),
    [
        ?assertEqual({error, {credential_not_allowed, U}}, livery_client:get(Client, U))
     || U <- [
            <<"https://evil.example/x">>,
            <<"http://api.example/x">>,
            <<"https://api.example:8443/x">>
        ]
    ],
    ?assertEqual(2, counters:get(Api, 1)).

resource_origins() ->
    C = counters:new(1, []),
    Api = counters:new(1, []),
    Client = client(C, fun token/1, sent_to(Api), #{
        allowed_origins => undefined, resource => <<"https://api.example/orders">>
    }),
    Client1 = (strip_allowed(Client))#{base_url => <<>>},
    {ok, _} = livery_client:get(Client1, <<"https://api.example/x">>),
    ?assertMatch(
        {error, {credential_not_allowed, _}},
        livery_client:get(Client1, <<"https://other.example/">>)
    ).

origins_required() ->
    C = counters:new(1, []),
    Client = strip_allowed(client(C, fun token/1, fun echo_auth/1)),
    ?assertEqual({error, {missing_option, allowed_origins}}, livery_client:get(Client, <<"/x">>)),
    ?assertEqual(0, counters:get(C, 1)).

%% A layer inside the oauth layer that points the request elsewhere, as a
%% balancer does, is caught before anything is sent.
rewritten_after() ->
    C = counters:new(1, []),
    Api = counters:new(1, []),
    Client0 = client(C, fun token/1, sent_to(Api)),
    Rewrite = fun(Req, Next) -> Next(Req#{url => <<"https://evil.example/x">>}) end,
    Client = Client0#{stack => maps:get(stack, Client0) ++ [Rewrite]},
    ?assertEqual(
        {error, {credential_not_allowed, <<"https://evil.example/x">>}},
        livery_client:get(Client, <<"/x">>)
    ),
    ?assertEqual(0, counters:get(Api, 1)).

%% Drop `allowed_origins' from the oauth layer of a test client.
strip_allowed(#{stack := [{livery_client_oauth, O}]} = Client) ->
    Client#{stack => [{livery_client_oauth, maps:remove(allowed_origins, O)}]}.
