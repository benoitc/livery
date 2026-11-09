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
`scope`, `resource` (RFC 8707), `allowed_origins` and `refresh_skew`.

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
""".

-export([call/3]).

-spec call(livery_client:request(), livery_client:next(), map()) ->
    {ok, livery_client:response()} | {error, term()}.
call(Req, Next, Opts) ->
    case origins(Opts) of
        {ok, Origins} -> call(bind(Req, Origins), Next, key(Opts), Opts);
        {error, _} = E -> E
    end.

call(Req, Next, Key, Opts) ->
    case token(Key, Opts) of
        {ok, Token} ->
            case Next(authorize(Req, Token)) of
                {ok, Resp} = Result ->
                    case rejected(Resp) andalso replayable(Req) of
                        true -> retry(Key, Req, Next, Opts);
                        false -> Result
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
        {ok, Token} -> Next(authorize(Req, Token));
        {error, _} = E -> E
    end.

token(Key, Opts) ->
    Params = maps:with([scope, resource], Opts),
    Fetch = fun() -> livery_auth_token:request(client_credentials, Params, Opts) end,
    case livery_client_token_store:get(Key, Fetch, maps:get(refresh_skew, Opts, 30)) of
        {ok, #{token_type := Type} = Token} ->
            case string:lowercase(Type) of
                <<"bearer">> -> {ok, Token};
                _ -> {error, {unsupported_token_type, Type}}
            end;
        {error, _} = E ->
            E
    end.

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

key(Opts) ->
    {
        maps:get(token_endpoint, Opts),
        maps:get(client_id, Opts),
        maps:get(scope, Opts, undefined),
        maps:get(resource, Opts, undefined)
    }.

authorize(Req, #{access_token := Access}) ->
    livery_client:set_header(<<"authorization">>, <<"Bearer ", Access/binary>>, Req).

rejected(Resp) ->
    livery_client:status(Resp) =:= 401 andalso
        case livery_client:header(<<"www-authenticate">>, Resp) of
            undefined -> false;
            Challenge -> binary:match(Challenge, <<"invalid_token">>) =/= nomatch
        end.

%% Same rule as `livery_client_retry': a streamed body cannot be replayed.
replayable(Req) ->
    case maps:get(body, Req, empty) of
        {stream, _} -> false;
        _ -> true
    end.
