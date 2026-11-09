-module(livery_auth_binding).
-moduledoc """
Sender-constrained tokens for `livery_auth_bearer` and
`livery_auth_introspect`.

Once a token is valid, `check/5` makes sure the client presenting it is
the one it was issued to, from the token's `cnf` claim:

- `x5t#S256` (RFC 8705 section 3): the request must come over a TLS
  connection with a verified client certificate whose SHA-256 is that
  value; see the guide on requiring client certificates.
- `jkt` (RFC 9449 section 7): the token must be sent with the `DPoP`
  scheme and a proof signed by the key with that thumbprint
  (`livery_auth_dpop`). A DPoP-bound token sent as `Bearer` is refused,
  and so is a token without `jkt` sent as `DPoP`.

`binding => mtls | dpop | any` additionally refuses tokens that are not
bound that way; the default `none` accepts unbound bearer tokens.
""".

-export([token/2, check/5, dpop_enabled/1, stripped/1]).

-type scheme() :: bearer | dpop.
-type failure() :: {invalid_token, binary()} | {invalid_dpop_proof, binary()}.

-export_type([scheme/0, failure/0]).

-doc """
The access token and the scheme it came with. A `DPoP` token is only
taken when the options accept that scheme; otherwise the request reads
as having no token.
""".
-spec token(livery_req:req(), map()) -> {scheme(), binary()} | undefined.
token(Req, Opts) ->
    case livery_ext:auth_token(Req) of
        {dpop, Token} ->
            case dpop_enabled(Opts) of
                true -> {dpop, Token};
                false -> undefined
            end;
        Other ->
            Other
    end.

-doc "The middleware options with the binding keys removed.".
-spec stripped(map()) -> map().
stripped(Opts) ->
    maps:without(
        [binding, dpop, dpop_url, dpop_replay, dpop_iat_window, realm, resource_metadata, required],
        Opts
    ).

-doc "Whether the middleware options accept the `DPoP` scheme.".
-spec dpop_enabled(map()) -> boolean().
dpop_enabled(Opts) ->
    maps:get(dpop, Opts, false) orelse lists:member(maps:get(binding, Opts, none), [dpop, any]).

-doc "Check that the client presenting a valid token is the one it is bound to.".
-spec check(scheme(), binary(), map(), livery_req:req(), map()) -> ok | {error, failure()}.
check(Scheme, Token, Claims, Req, Opts) ->
    Cnf =
        case maps:get(<<"cnf">>, Claims, #{}) of
            #{} = C -> C;
            _ -> #{}
        end,
    Jkt = maps:get(<<"jkt">>, Cnf, undefined),
    X5t = maps:get(<<"x5t#S256">>, Cnf, undefined),
    Steps = [
        fun() -> required(maps:get(binding, Opts, none), Jkt, X5t) end,
        fun() -> dpop(Scheme, Jkt, Token, Req, Opts) end,
        fun() -> certificate(X5t, Req) end
    ],
    run(Steps).

run([]) ->
    ok;
run([Step | Rest]) ->
    case Step() of
        ok -> run(Rest);
        {error, _} = E -> E
    end.

required(none, _Jkt, _X5t) -> ok;
required(dpop, Jkt, _X5t) when is_binary(Jkt) -> ok;
required(mtls, _Jkt, X5t) when is_binary(X5t) -> ok;
required(any, Jkt, X5t) when is_binary(Jkt); is_binary(X5t) -> ok;
required(_, _, _) -> {error, {invalid_token, <<"token is not sender-constrained">>}}.

dpop(bearer, undefined, _Token, _Req, _Opts) ->
    ok;
dpop(bearer, _Jkt, _Token, _Req, _Opts) ->
    {error, {invalid_token, <<"DPoP-bound token sent as Bearer">>}};
dpop(dpop, undefined, _Token, _Req, _Opts) ->
    {error, {invalid_token, <<"token is not DPoP-bound">>}};
dpop(dpop, Jkt, Token, Req, Opts) ->
    case livery_auth_dpop:verify_proof(Req, Token, Opts) of
        {ok, Jkt} -> ok;
        {ok, _Other} -> {error, {invalid_dpop_proof, <<"proof key does not match the token">>}};
        {error, Reason} -> {error, {invalid_dpop_proof, proof_text(Reason)}}
    end.

certificate(undefined, _Req) ->
    ok;
certificate(X5t, Req) ->
    case livery_req:tls(Req) of
        #{verified := true, cert := Der} ->
            case base64:encode(crypto:hash(sha256, Der), #{mode => urlsafe, padding => false}) of
                X5t -> ok;
                _ -> {error, {invalid_token, <<"client certificate does not match the token">>}}
            end;
        _ ->
            {error, {invalid_token, <<"token needs a client certificate">>}}
    end.

proof_text(missing_proof) -> <<"missing DPoP proof">>;
proof_text(multiple_proofs) -> <<"more than one DPoP proof">>;
proof_text(malformed_proof) -> <<"malformed DPoP proof">>;
proof_text(replayed_proof) -> <<"DPoP proof already used">>;
proof_text({invalid_proof, What}) -> <<"invalid DPoP proof: ", What/binary>>.
