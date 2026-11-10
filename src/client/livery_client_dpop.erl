-module(livery_client_dpop).
-moduledoc """
DPoP proofs for outbound requests (RFC 9449, client side).

A DPoP-bound token is useless on its own: every request that carries it
also carries a proof, a short JWT signed with a key only this client
holds, naming the method and URL of that request. `livery_client_oauth`
uses this module when you pass it `dpop`; you only call it directly to
send proofs from your own layer.

`new/2` makes a context: the signing key, its public JWK and its
thumbprint (RFC 7638), which the authorization server puts in the
token's `cnf.jkt`. A key you pass with `key => {Alg, PrivateKey}` is
used as is. Without one, an ES256 key is generated the first time a
`Scope` is seen and shared by every context of that scope on this node,
so rebuilding a client does not change the key, and the cached tokens
stay usable. That key lives in memory only: after a restart a new one is
made and new tokens are fetched for it.

`proof/4` signs a proof for a method and URL, with `ath` when it goes
with an access token. `htu` is the URL without query and fragment
(section 4.2). The server may ask for a nonce (section 8 and 9): the
last `DPoP-Nonce` a server sent is kept per key and origin, and put in
the next proof to that origin.
""".

-export([new/2, thumbprint/1, proof/4, remember/3, send/2]).
-export([table/0]).

-define(TABLE, livery_client_dpop).

-opaque ctx() :: #{key := {binary(), term()}, jwk := map(), jkt := binary()}.
-export_type([ctx/0]).

-doc "The ETS table of generated keys and nonces, created by `livery_client_token_store`.".
-spec table() -> atom().
table() -> ?TABLE.

-doc """
A DPoP context from `Opts` (`#{key => {Alg, PrivateKey}}`, or `#{}` for
a generated ES256 key shared by every context made with `Scope`).
""".
-spec new(term(), map()) -> ctx().
new(Scope, Opts) ->
    Key =
        case maps:find(key, Opts) of
            {ok, K} -> K;
            error -> generated(Scope)
        end,
    Jwk = livery_auth_jose:public_jwk(Key),
    #{key => Key, jwk => Jwk, jkt => livery_auth_dpop:thumbprint(Jwk)}.

generated(Scope) ->
    New = {<<"ES256">>, public_key:generate_key({namedCurve, secp256r1})},
    _ = ets:insert_new(?TABLE, {{key, Scope}, New}),
    [{_, Key}] = ets:lookup(?TABLE, {key, Scope}),
    Key.

-doc "The RFC 7638 thumbprint of the context's key.".
-spec thumbprint(ctx()) -> binary().
thumbprint(#{jkt := Jkt}) -> Jkt.

-doc """
A proof for `Method` on `Url`, bound to `AccessToken` (or `undefined`
at the token endpoint), with the last nonce the origin of `Url` sent.
""".
-spec proof(ctx(), atom() | binary(), binary(), binary() | undefined) -> binary().
proof(#{key := {Alg, _} = Key, jwk := Jwk} = Ctx, Method, Url, AccessToken) ->
    Header = #{<<"typ">> => <<"dpop+jwt">>, <<"alg">> => Alg, <<"jwk">> => Jwk},
    Claims0 = #{
        <<"jti">> => b64(crypto:strong_rand_bytes(16)),
        <<"htm">> => string:uppercase(to_binary(Method)),
        <<"htu">> => htu(Url),
        <<"iat">> => os:system_time(second)
    },
    Claims1 =
        case AccessToken of
            undefined -> Claims0;
            _ -> Claims0#{<<"ath">> => b64(crypto:hash(sha256, AccessToken))}
        end,
    Claims =
        case nonce(Ctx, Url) of
            undefined -> Claims1;
            Nonce -> Claims1#{<<"nonce">> => Nonce}
        end,
    livery_auth_jose:sign(Key, Header, Claims).

-doc "Keep the `DPoP-Nonce` of a response from `Url`, if it has one.".
-spec remember(ctx(), binary(), [{binary(), binary()}]) -> ok.
remember(#{jkt := Jkt}, Url, Headers) ->
    case {nonce_header(Headers), livery_client:origin(Url)} of
        {Nonce, {ok, Origin}} when is_binary(Nonce) ->
            try ets:insert(?TABLE, {{nonce, Jkt, Origin}, Nonce}) of
                true -> ok
            catch
                error:badarg -> ok
            end;
        _ ->
            ok
    end.

-doc """
Send `Req` with `Send`, adding a proof when `livery_client_oauth` put a
DPoP token in its `meta`, and keeping the nonce of the answer. Called by
`livery_client` once the URL is final.
""".
-spec send(livery_client:request(), fun((livery_client:request()) -> Result)) -> Result when
    Result :: {ok, livery_client:response()} | {error, term()}.
send(#{meta := #{dpop := {Ctx, Token}}, method := Method, url := Url} = Req, Send) ->
    Proof = proof(Ctx, Method, Url, Token),
    Result = Send(livery_client:set_header(<<"dpop">>, Proof, Req)),
    case Result of
        {ok, #{headers := Headers}} -> remember(Ctx, Url, Headers);
        _ -> ok
    end,
    Result;
send(Req, Send) ->
    Send(Req).

nonce(#{jkt := Jkt}, Url) ->
    case livery_client:origin(Url) of
        {ok, Origin} ->
            try ets:lookup(?TABLE, {nonce, Jkt, Origin}) of
                [{_, Nonce}] -> Nonce;
                [] -> undefined
            catch
                error:badarg -> undefined
            end;
        error ->
            undefined
    end.

nonce_header(Headers) ->
    case [V || {K, V} <- Headers, string:lowercase(K) =:= <<"dpop-nonce">>] of
        [Nonce | _] when Nonce =/= <<>> -> Nonce;
        _ -> undefined
    end.

%% RFC 9449 4.2: the target URI without query and fragment.
htu(Url) ->
    case uri_string:parse(Url) of
        #{} = Parts ->
            iolist_to_binary(uri_string:recompose(maps:without([query, fragment], Parts)));
        _ ->
            Url
    end.

to_binary(A) when is_atom(A) -> atom_to_binary(A);
to_binary(B) when is_binary(B) -> B.

b64(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).
