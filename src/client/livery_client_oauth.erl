-module(livery_client_oauth).
-moduledoc """
Client layer: OAuth 2.0 client credentials (RFC 6749 section 4.4).

Adds `Authorization: Bearer <token>` to every request, with a token the
layer gets from the authorization server and caches in
`livery_client_token_store`. A token is reused until `refresh_skew`
seconds (default 30) before it expires; when it runs out, concurrent
requests wait for a single new one. Add it with `livery_client:oauth/1`.

`Opts` are the `livery_auth_token` options (`token_endpoint`,
`client_id`, `client_auth`, `client_secret` or `private_key`, ...) plus
`scope`, `resource` (RFC 8707), `allowed_origins`, `refresh_skew` and
`dpop`.

The token goes only to the origins it is for: `allowed_origins` (URLs,
compared by scheme, host and port), or the origins of `resource` when
that is set instead. One of the two is required. The check runs in
`livery_client` just before the request leaves, after every other layer,
so a URL rewritten by `livery_client_balance` or passed in absolute form
cannot carry the token to another host; such a request fails with
`{error, {credential_not_allowed, Url}}` and is not sent.

When the API answers `401` with `error="invalid_token"`, the token was
revoked or rotated early: the layer drops it, gets a new one and sends
the request once more, unless its body is a stream that cannot be sent
twice.

With `dpop => true`, tokens are bound to a key this client holds (RFC
9449): the token request and every API request carry a proof signed
with it, and the API gets `Authorization: DPoP <token>`, so a token that
leaks cannot be used without the key. The key is generated once per
client and token endpoint on this node, or given as `dpop => #{key =>
{Alg, PrivateKey}}`; see `livery_client_dpop`. A nonce a server asks for
(`use_dpop_nonce`) is sent on a second attempt, then on every later
proof to that origin. An authorization server may still answer with a
bearer token, which is then sent as bearer; add `require => true` to the
`dpop` map to refuse it with `{error, {unsupported_token_type, Type}}`.
""".

-export([call/3]).

-spec call(livery_client:request(), livery_client:next(), map()) ->
    {ok, livery_client:response()} | {error, term()}.
call(Req, Next, Opts) ->
    case origins(Opts) of
        {ok, Origins} ->
            Ctx = dpop(Opts),
            call(bind(Req, Origins), Next, key(Opts, Ctx), token_opts(Opts, Ctx));
        {error, _} = E ->
            E
    end.

call(Req, Next, Key, Opts) ->
    case token(Key, Opts) of
        {ok, Token} ->
            case Next(authorize(Req, Token, Opts)) of
                {ok, Resp} = Result ->
                    case replayable(Req) andalso rejected(Resp, Token) of
                        false -> Result;
                        use_dpop_nonce -> Next(authorize(Req, Token, Opts));
                        invalid_token -> retry(Key, Req, Next, Opts)
                    end;
                Error ->
                    Error
            end;
        {error, _} = E ->
            E
    end.

retry(Key, Req, Next, Opts) ->
    ok = livery_client_token_store:invalidate(Key),
    case token(Key, Opts) of
        {ok, Token} -> Next(authorize(Req, Token, Opts));
        {error, _} = E -> E
    end.

token(Key, Opts) ->
    Params = maps:with([scope, resource], Opts),
    Fetch = fun() -> livery_auth_token:request(client_credentials, Params, Opts) end,
    case livery_client_token_store:get(Key, Fetch, maps:get(refresh_skew, Opts, 30)) of
        {ok, #{token_type := Type} = Token} ->
            case {string:lowercase(Type), Opts} of
                {<<"bearer">>, #{dpop_require := true}} -> {error, {unsupported_token_type, Type}};
                {<<"bearer">>, _} -> {ok, Token#{scheme => bearer}};
                {<<"dpop">>, #{dpop := _}} -> {ok, Token#{scheme => dpop}};
                _ -> {error, {unsupported_token_type, Type}}
            end;
        {error, _} = E ->
            E
    end.

%% RFC 9449: `dpop => true' or `#{key => {Alg, Priv}, require => boolean()}'.
%% A generated key is shared by every layer for the same client and token
%% endpoint, so rebuilding the layer keeps its cached tokens usable.
dpop(#{dpop := false}) ->
    undefined;
dpop(#{dpop := Dpop} = Opts) ->
    Cfg =
        case Dpop of
            true -> #{};
            #{} -> Dpop
        end,
    livery_client_dpop:new(key(Opts, undefined), Cfg);
dpop(_Opts) ->
    undefined.

token_opts(Opts, undefined) ->
    maps:remove(dpop, Opts);
token_opts(#{dpop := Cfg} = Opts, Ctx) ->
    Opts#{dpop => Ctx, dpop_require => required(Cfg)}.

required(#{require := true}) -> true;
required(_Cfg) -> false.

origins(#{allowed_origins := Urls}) -> parse_origins(Urls);
origins(#{resource := Resource}) -> parse_origins(lists:flatten([Resource]));
origins(_Opts) -> {error, {missing_option, allowed_origins}}.

parse_origins(Urls) ->
    case [livery_client:origin(U) || U <- Urls] of
        [] ->
            {error, {missing_option, allowed_origins}};
        Parsed ->
            case [O || {ok, O} <- Parsed] of
                Ok when length(Ok) =:= length(Parsed) -> {ok, Ok};
                _ -> {error, {invalid_option, allowed_origins}}
            end
    end.

%% Several credential layers each narrow where the request may go.
bind(Req, Origins) ->
    Meta = maps:get(meta, Req, #{}),
    Allowed =
        case maps:find(credential_origins, Meta) of
            {ok, Prev} -> [O || O <- Prev, lists:member(O, Origins)];
            error -> Origins
        end,
    Req#{meta => Meta#{credential_origins => Allowed}}.

%% Tokens bound to different keys are different tokens.
key(Opts, Ctx) ->
    {
        maps:get(token_endpoint, Opts),
        maps:get(client_id, Opts),
        maps:get(scope, Opts, undefined),
        maps:get(resource, Opts, undefined),
        case Ctx of
            undefined -> undefined;
            _ -> livery_client_dpop:thumbprint(Ctx)
        end
    }.

authorize(Req, #{scheme := bearer, access_token := Access}, _Opts) ->
    livery_client:set_header(<<"authorization">>, <<"Bearer ", Access/binary>>, Req);
authorize(Req, #{scheme := dpop, access_token := Access}, #{dpop := Ctx}) ->
    Meta = maps:get(meta, Req, #{}),
    Req1 = livery_client:set_header(<<"authorization">>, <<"DPoP ", Access/binary>>, Req),
    Req1#{meta => Meta#{dpop => {Ctx, Access}}}.

%% A 401 asking for a DPoP nonce (RFC 9449 section 9) is sent again with
%% the same token, the nonce now known; `invalid_token' needs a new token.
rejected(Resp, Token) ->
    case livery_client:status(Resp) of
        401 -> challenge(livery_client:header(<<"www-authenticate">>, Resp), Resp, Token);
        _ -> false
    end.

challenge(undefined, _Resp, _Token) ->
    false;
challenge(Challenge, Resp, #{scheme := Scheme}) ->
    Has = fun(Word) -> binary:match(Challenge, Word) =/= nomatch end,
    Nonce = livery_client:header(<<"dpop-nonce">>, Resp) =/= undefined,
    if_first([
        {Scheme =:= dpop andalso Nonce andalso Has(<<"use_dpop_nonce">>), use_dpop_nonce},
        {Has(<<"invalid_token">>), invalid_token}
    ]).

if_first([{true, R} | _]) -> R;
if_first([_ | T]) -> if_first(T);
if_first([]) -> false.

%% Same rule as `livery_client_retry': a streamed body cannot be replayed.
replayable(Req) ->
    case maps:get(body, Req, empty) of
        {stream, _} -> false;
        _ -> true
    end.
