-module(livery_auth_oidc).
-moduledoc """
OIDC provider discovery.

`discover/1,2` fetches an issuer's
`/.well-known/openid-configuration` document and returns it as a
decoded map (notably `jwks_uri`, `issuer`, `authorization_endpoint`,
`token_endpoint`). Feed the `jwks_uri` to `livery_auth_jwks:keys/1`
to get verification keys. `discover_oauth/1,2` does the same for an
OAuth 2.0 authorization server's metadata (RFC 8414).

The document's `issuer` must be exactly the issuer you passed, as
OpenID Connect Discovery 1.0 section 4.3 requires. Otherwise you get
`{error, issuer_mismatch}`, or `{error, invalid_discovery}` when it
names none.

Deviations: only `issuer` is checked; the other REQUIRED metadata
fields are returned as the provider sent them. See AGENTS.md, Known deviations.

The HTTP fetch is pluggable via `fetch => fun((Url) -> {ok, Body}
| {error, _})`; the default uses `livery_auth_jwks:default_fetch/1`
(`hackney`).

```erlang
{ok, Cfg}  = livery_auth_oidc:discover(<<"https://issuer.example">>),
JwksUri    = maps:get(<<"jwks_uri">>, Cfg),
{ok, Keys} = livery_auth_jwks:keys(JwksUri).
```
""".

-export([discover/1, discover/2, well_known_url/1]).
-export([discover_oauth/1, discover_oauth/2, oauth_well_known_url/1]).

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
    fetch_metadata(Issuer, well_known_url(Issuer), Opts).

-doc """
Fetch and parse an OAuth 2.0 authorization server's metadata (RFC 8414)
for an issuer. Same checks and errors as `discover/2`.
""".
-spec discover_oauth(binary()) -> {ok, config()} | {error, term()}.
discover_oauth(Issuer) -> discover_oauth(Issuer, #{}).

-spec discover_oauth(binary(), opts()) -> {ok, config()} | {error, term()}.
discover_oauth(Issuer, Opts) ->
    fetch_metadata(Issuer, oauth_well_known_url(Issuer), Opts).

-doc """
Build the RFC 8414 metadata URL for an issuer. The well-known segment
goes between the host and the issuer's path (RFC 8414 3.1), so
`https://as.example/tenant` becomes
`https://as.example/.well-known/oauth-authorization-server/tenant`.
""".
-spec oauth_well_known_url(binary()) -> binary().
oauth_well_known_url(Issuer) ->
    #{path := Path} = Parts = uri_string:parse(Issuer),
    Suffix = string:trim(Path, trailing, "/"),
    New = Parts#{path => <<"/.well-known/oauth-authorization-server", Suffix/binary>>},
    unicode:characters_to_binary(uri_string:recompose(New)).

%% OpenID Connect Discovery 1.0 4.3 and RFC 8414 3.3: the document must
%% name the issuer it was fetched for, or a provider could hand out
%% another one's keys and issuer.
fetch_metadata(Issuer, Url, Opts) ->
    Fetch = maps:get(fetch, Opts, fun livery_auth_jwks:default_fetch/1),
    case Fetch(Url) of
        {ok, Body} ->
            try json:decode(Body) of
                #{<<"issuer">> := Issuer} = Config -> {ok, Config};
                #{<<"issuer">> := _} -> {error, issuer_mismatch};
                _ -> {error, invalid_discovery}
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
