-module(livery_auth_dpop).
-moduledoc """
DPoP proof checks for a resource server (RFC 9449 section 4.3).

A DPoP-bound access token comes with a `DPoP` header: a JWT the client
signs, on every request, with a key it keeps. `verify_proof/3` checks
that proof and returns the key's thumbprint (RFC 7638), which the
token's `cnf.jkt` must equal. `livery_auth_bearer` and
`livery_auth_introspect` call it; you only need it directly to check
proofs outside those middlewares.

The checks, in order: exactly one `DPoP` header; `typ` `dpop+jwt`; an
`alg` from the allow list; a public `jwk` in the header, with no private
members; a valid signature by that key; `htm` equal to the request
method; `htu` equal to the request URL without query and fragment,
after RFC 3986 normalisation; `iat` no older than `dpop_iat_window`
seconds (default 60) and not in the future, give or take `leeway`;
`ath` equal to the hash of the access token; a `jti` not seen before.

Options: `algorithms`, `leeway`, `now`, `dpop_iat_window`, and
`dpop_url => fun((Req) -> binary())` when a proxy changes the URL the
client used, and `dpop_replay => fun((Key, ExpiresAt) -> fresh |
replayed)` to replace the node-local replay store.

With `dpop_nonce => #{secret => Secret}`, every proof must also carry a
`nonce` this server issued (RFC 9449 section 9), so a proof cannot be
made in advance, before the server handed out the nonce. `nonce/1`
issues one. A nonce is a timestamp signed with `Secret`, valid for `ttl`
seconds (default 300): nothing is stored, and every node that shares
the secret accepts the nonces of the others. A proof without a valid
nonce fails with `use_dpop_nonce`, which the middlewares answer with a
fresh nonce in a `DPoP-Nonce` header.
""".

-export([verify_proof/3, thumbprint/1, nonce/1, nonce_enabled/1]).

-type error_reason() ::
    missing_proof
    | multiple_proofs
    | malformed_proof
    | {invalid_proof, binary()}
    | replayed_proof
    | use_dpop_nonce.

-export_type([error_reason/0]).

-define(PRIVATE, [<<"d">>, <<"p">>, <<"q">>, <<"dp">>, <<"dq">>, <<"qi">>, <<"oth">>, <<"k">>]).

-doc "Check the request's DPoP proof for `AccessToken`; returns the key thumbprint.".
-spec verify_proof(livery_req:req(), binary(), map()) ->
    {ok, binary()} | {error, error_reason()}.
verify_proof(Req, AccessToken, Opts) ->
    case [V || {<<"dpop">>, V} <- livery_req:headers(Req)] of
        [] -> {error, missing_proof};
        [Proof] -> check_proof(Proof, Req, AccessToken, Opts);
        _ -> {error, multiple_proofs}
    end.

-doc "Whether the options ask for server-provided nonces.".
-spec nonce_enabled(map()) -> boolean().
nonce_enabled(#{dpop_nonce := #{secret := Secret}}) when is_binary(Secret) -> true;
nonce_enabled(_) -> false.

-doc """
A fresh nonce for the `DPoP-Nonce` header: the current time and an HMAC
of it under the `dpop_nonce` secret, base64url encoded.
""".
-spec nonce(map()) -> binary().
nonce(#{dpop_nonce := #{secret := Secret}} = Opts) ->
    Ts = maps:get(now, Opts, os:system_time(second)),
    b64(<<Ts:64, (nonce_mac(Secret, Ts))/binary>>).

-doc "RFC 7638 SHA-256 thumbprint of a public JWK, base64url without padding.".
-spec thumbprint(map()) -> binary() | error.
thumbprint(#{<<"kty">> := Kty} = Jwk) ->
    case required_members(Kty) of
        error ->
            error;
        Names ->
            Members = [{N, maps:get(N, Jwk, undefined)} || N <- Names],
            case lists:all(fun({_, V}) -> is_binary(V) end, Members) of
                true -> b64(crypto:hash(sha256, canonical(Members)));
                false -> error
            end
    end;
thumbprint(_) ->
    error.

%%====================================================================
%% Proof
%%====================================================================

check_proof(Proof, Req, AccessToken, Opts) ->
    case binary:split(Proof, <<".">>, [global]) of
        [H, P, S] ->
            case
                {
                    livery_auth_jose:decode_json(H),
                    livery_auth_jose:decode_json(P),
                    livery_auth_jose:b64url(S)
                }
            of
                {{ok, Header}, {ok, Claims}, {ok, Sig}} ->
                    check_header(
                        Header, Claims, Sig, <<H/binary, ".", P/binary>>, Req, AccessToken, Opts
                    );
                _ ->
                    {error, malformed_proof}
            end;
        _ ->
            {error, malformed_proof}
    end.

check_header(Header, Claims, Sig, Input, Req, AccessToken, Opts) ->
    case {maps:get(<<"typ">>, Header, undefined), maps:get(<<"jwk">>, Header, undefined)} of
        {Typ, Jwk} when is_binary(Typ), is_map(Jwk) ->
            case string:lowercase(Typ) =:= <<"dpop+jwt">> of
                false -> invalid(<<"typ">>);
                true -> check_key(Header, Jwk, Claims, Sig, Input, Req, AccessToken, Opts)
            end;
        {Typ, _} when is_binary(Typ) ->
            invalid(<<"jwk">>);
        _ ->
            invalid(<<"typ">>)
    end.

check_key(Header, Jwk, Claims, Sig, Input, Req, AccessToken, Opts) ->
    Private = [N || N <- ?PRIVATE, maps:is_key(N, Jwk)],
    Allowed = maps:get(algorithms, Opts, livery_auth_jose:algorithms()),
    case {Private, thumbprint(Jwk)} of
        {[], Jkt} when is_binary(Jkt) ->
            Alg = maps:get(<<"alg">>, Header, undefined),
            Key = maps:without([<<"kid">>, <<"alg">>, <<"use">>, <<"key_ops">>], Jwk),
            case livery_auth_jose:verify(Alg, undefined, Input, Sig, [Key], Allowed) of
                ok -> check_claims(Claims, Jkt, Req, AccessToken, Opts);
                {error, {unsupported_alg, _}} -> invalid(<<"alg">>);
                {error, _} -> invalid(<<"signature">>)
            end;
        _ ->
            invalid(<<"jwk">>)
    end.

check_claims(Claims, Jkt, Req, AccessToken, Opts) ->
    Now = maps:get(now, Opts, os:system_time(second)),
    Leeway = maps:get(leeway, Opts, 0),
    Window = maps:get(dpop_iat_window, Opts, 60),
    Iat = maps:get(<<"iat">>, Claims, undefined),
    Jti = maps:get(<<"jti">>, Claims, undefined),
    Checks = [
        {<<"jti">>, is_binary(Jti) andalso Jti =/= <<>>},
        {<<"htm">>, maps:get(<<"htm">>, Claims, undefined) =:= livery_req:method(Req)},
        {<<"htu">>, same_url(maps:get(<<"htu">>, Claims, undefined), request_url(Req, Opts))},
        {<<"iat">>,
            is_number(Iat) andalso Iat >= Now - Window - Leeway andalso Iat =< Now + Leeway},
        {<<"ath">>,
            maps:get(<<"ath">>, Claims, undefined) =:= b64(crypto:hash(sha256, AccessToken))}
    ],
    case [Name || {Name, false} <- Checks] of
        [] ->
            case nonce_ok(maps:get(<<"nonce">>, Claims, undefined), Now, Leeway, Opts) of
                true ->
                    claim(<<Jkt/binary, 0, Jti/binary>>, trunc(Iat) + Window + Leeway, Jkt, Opts);
                false ->
                    {error, use_dpop_nonce}
            end;
        [First | _] ->
            invalid(First)
    end.

claim(Key, ExpiresAt, Jkt, Opts) ->
    Claim = maps:get(dpop_replay, Opts, fun livery_auth_dpop_store:claim/2),
    case Claim(Key, ExpiresAt) of
        fresh -> {ok, Jkt};
        replayed -> {error, replayed_proof}
    end.

invalid(What) ->
    {error, {invalid_proof, What}}.

%%====================================================================
%% Nonce (RFC 9449 section 9)
%%====================================================================

nonce_ok(Nonce, Now, Leeway, #{dpop_nonce := #{secret := Secret} = Cfg}) when is_binary(Nonce) ->
    Ttl = maps:get(ttl, Cfg, 300),
    case livery_auth_jose:b64url(Nonce) of
        {ok, <<Ts:64, Mac:16/binary>>} ->
            crypto:hash_equals(Mac, nonce_mac(Secret, Ts)) andalso
                Ts =< Now + Leeway andalso
                Now - Ts =< Ttl + Leeway;
        _ ->
            false
    end;
nonce_ok(_Nonce, _Now, _Leeway, #{dpop_nonce := #{secret := _}}) ->
    false;
nonce_ok(_Nonce, _Now, _Leeway, _Opts) ->
    true.

nonce_mac(Secret, Ts) ->
    binary:part(crypto:mac(hmac, sha256, Secret, <<"livery-dpop-nonce", Ts:64>>), 0, 16).

%%====================================================================
%% URL
%%====================================================================

request_url(Req, #{dpop_url := Fun}) ->
    Fun(Req);
request_url(Req, _Opts) ->
    iolist_to_binary([
        livery_req:scheme(Req), <<"://">>, livery_req:authority(Req), livery_req:path(Req)
    ]).

%% RFC 9449 4.3 point 9: compare without query and fragment, after
%% syntax- and scheme-based normalisation (RFC 3986 6.2.2 and 6.2.3).
same_url(Htu, Url) when is_binary(Htu) ->
    case {base_url(Htu), base_url(Url)} of
        {{ok, A}, {ok, A}} -> true;
        _ -> false
    end;
same_url(_, _) ->
    false.

base_url(Url) ->
    case uri_string:normalize(Url, [return_map]) of
        #{scheme := _, host := _} = Map ->
            {ok,
                maps:without([query, fragment], Map#{
                    path => default_path(maps:get(path, Map, <<>>))
                })};
        _ ->
            error
    end.

default_path(<<>>) -> <<"/">>;
default_path(Path) -> Path.

%%====================================================================
%% Thumbprint
%%====================================================================

required_members(<<"RSA">>) -> [<<"e">>, <<"kty">>, <<"n">>];
required_members(<<"EC">>) -> [<<"crv">>, <<"kty">>, <<"x">>, <<"y">>];
required_members(<<"OKP">>) -> [<<"crv">>, <<"kty">>, <<"x">>];
required_members(_) -> error.

%% RFC 7638 3.3: the required members only, in lexicographic order, with
%% no whitespace.
canonical(Members) ->
    Pairs = [[json:encode(N), $:, json:encode(V)] || {N, V} <- Members],
    iolist_to_binary([${, lists:join($,, Pairs), $}]).

b64(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).
