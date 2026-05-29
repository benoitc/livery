-module(livery_auth_jwks).
-moduledoc """
JWKS fetching, parsing, and caching with key rotation.

`keys/1,2` returns the JWK set for a `jwks_uri`, fetching it over
HTTP on first use and caching the result in `persistent_term`
with a TTL. `refresh/1,2` forces a re-fetch — call it on a
`no_matching_key` verification failure to pick up a rotated key.

The HTTP fetch is pluggable via `fetch => fun((Url) -> {ok, Body}
| {error, _})` in the options, so deployments (and tests) can
supply their own client. The default uses OTP's `httpc` (inets),
started lazily; no extra dependency.

```erlang
{ok, Keys} = livery_auth_jwks:keys(<<"https://issuer/.well-known/jwks.json">>),
{ok, Claims} = livery_auth:verify(Token, #{keys => Keys, issuer => Iss}).
```
""".

-export([
    keys/1,
    keys/2,
    refresh/1,
    refresh/2,
    from_json/1,
    default_fetch/1
]).

-export_type([opts/0]).

-type opts() :: #{
    fetch => fun((binary()) -> {ok, binary()} | {error, term()}),
    ttl => non_neg_integer()
}.

%% 5 minutes
-define(DEFAULT_TTL_MS, 300000).

%%====================================================================
%% Cache API
%%====================================================================

-doc "JWK set for `JwksUri`, cached with the default 5-minute TTL.".
-spec keys(binary()) -> {ok, [livery_auth:jwk()]} | {error, term()}.
keys(JwksUri) -> keys(JwksUri, #{}).

-doc "JWK set for `JwksUri`. Honors `fetch` and `ttl` options.".
-spec keys(binary(), opts()) -> {ok, [livery_auth:jwk()]} | {error, term()}.
keys(JwksUri, Opts) ->
    Now = erlang:monotonic_time(millisecond),
    case persistent_term:get(cache_key(JwksUri), undefined) of
        {Keys, Expiry} when Expiry > Now ->
            {ok, Keys};
        _ ->
            refresh(JwksUri, Opts)
    end.

-doc "Force a re-fetch of `JwksUri`, replacing the cached entry.".
-spec refresh(binary()) -> {ok, [livery_auth:jwk()]} | {error, term()}.
refresh(JwksUri) -> refresh(JwksUri, #{}).

-spec refresh(binary(), opts()) -> {ok, [livery_auth:jwk()]} | {error, term()}.
refresh(JwksUri, Opts) ->
    Fetch = maps:get(fetch, Opts, fun default_fetch/1),
    case Fetch(JwksUri) of
        {ok, Body} ->
            case decode_jwks(Body) of
                {ok, Keys} ->
                    Ttl = maps:get(ttl, Opts, ?DEFAULT_TTL_MS),
                    Expiry = erlang:monotonic_time(millisecond) + Ttl,
                    persistent_term:put(cache_key(JwksUri), {Keys, Expiry}),
                    {ok, Keys};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%%====================================================================
%% Parsing
%%====================================================================

-doc "Parse a JWKS document (binary or decoded map) into a key list.".
-spec from_json(binary() | map()) -> {ok, [livery_auth:jwk()]} | {error, term()}.
from_json(Bin) when is_binary(Bin) ->
    decode_jwks(Bin);
from_json(#{<<"keys">> := Keys}) when is_list(Keys) ->
    {ok, Keys};
from_json(_) ->
    {error, invalid_jwks}.

-spec decode_jwks(binary()) -> {ok, [livery_auth:jwk()]} | {error, term()}.
decode_jwks(Body) ->
    try json:decode(Body) of
        #{<<"keys">> := Keys} when is_list(Keys) -> {ok, Keys};
        _ -> {error, invalid_jwks}
    catch
        _:_ -> {error, invalid_json}
    end.

%%====================================================================
%% Default HTTP fetcher (OTP httpc)
%%====================================================================

-doc "Default JWKS fetcher using OTP `httpc`. Starts inets/ssl lazily.".
-spec default_fetch(binary()) -> {ok, binary()} | {error, term()}.
default_fetch(Url) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Request = {binary_to_list(Url), []},
    case
        httpc:request(
            get,
            Request,
            [{timeout, 5000}, {ssl, livery_auth:tls_opts()}],
            [{body_format, binary}]
        )
    of
        {ok, {{_Vsn, 200, _}, _Headers, Body}} ->
            {ok, Body};
        {ok, {{_Vsn, Code, _}, _Headers, _Body}} ->
            {error, {http_status, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

%%====================================================================
%% Helpers
%%====================================================================

cache_key(JwksUri) ->
    {?MODULE, JwksUri}.
