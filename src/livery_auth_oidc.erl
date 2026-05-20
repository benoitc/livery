-module(livery_auth_oidc).
-moduledoc """
OIDC provider discovery.

`discover/1,2` fetches an issuer's
`/.well-known/openid-configuration` document and returns it as a
decoded map (notably `jwks_uri`, `issuer`, `authorization_endpoint`,
`token_endpoint`). Feed the `jwks_uri` to `livery_auth_jwks:keys/1`
to get verification keys.

The HTTP fetch is pluggable via `fetch => fun((Url) -> {ok, Body}
| {error, _})`; the default uses `livery_auth_jwks:default_fetch/1`
(OTP `httpc`).

```erlang
{ok, Cfg}  = livery_auth_oidc:discover(<<"https://issuer.example">>),
JwksUri    = maps:get(<<"jwks_uri">>, Cfg),
{ok, Keys} = livery_auth_jwks:keys(JwksUri).
```
""".

-export([discover/1, discover/2, well_known_url/1]).

-export_type([opts/0, config/0]).

-type opts() :: #{
    fetch => fun((binary()) -> {ok, binary()} | {error, term()})
}.
-type config() :: #{binary() => term()}.

-doc "Fetch and parse the OIDC discovery document for an issuer.".
-spec discover(binary()) -> {ok, config()} | {error, term()}.
discover(Issuer) -> discover(Issuer, #{}).

-spec discover(binary(), opts()) -> {ok, config()} | {error, term()}.
discover(Issuer, Opts) ->
    Fetch = maps:get(fetch, Opts, fun livery_auth_jwks:default_fetch/1),
    Url = well_known_url(Issuer),
    case Fetch(Url) of
        {ok, Body} ->
            try json:decode(Body) of
                #{<<"issuer">> := _} = Config -> {ok, Config};
                #{} = Config                  -> {ok, Config};
                _                             -> {error, invalid_discovery}
            catch
                _:_ -> {error, invalid_json}
            end;
        {error, _} = E ->
            E
    end.

-doc "Build the discovery URL for an issuer (handles a trailing slash).".
-spec well_known_url(binary()) -> binary().
well_known_url(Issuer) ->
    Trimmed = string:trim(Issuer, trailing, "/"),
    Base = unicode:characters_to_binary(Trimmed),
    <<Base/binary, "/.well-known/openid-configuration">>.
