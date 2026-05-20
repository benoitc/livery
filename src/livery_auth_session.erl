-module(livery_auth_session).
-moduledoc """
Signed session-cookie middleware.

Reads a cookie, verifies its HMAC-SHA256 signature against a shared
`secret`, decodes the JSON payload, and stores it on the request as
`meta(session, Data)` (read it back with `livery_ext:session/1`).
The cookie is stateless: the signed payload travels with the
client, so no server-side session store is needed.

State:

```erlang
{livery_auth_session, #{
    secret   => <<"a long random secret">>,  %% required
    name     => <<"session">>,                %% cookie name, default
    meta_key => session,                      %% meta key, default
    required => false                         %% default false
}}
```

A missing cookie is allowed through when `required => false` (the
default); the handler sees no `session` meta. A present but
tampered or expired cookie is always rejected with `401`.

Issue and clear cookies from a handler with `sign/2` plus
`set_cookie_header/2` and `clear_cookie_header/1`:

```erlang
login(Req) ->
    Value = livery_auth_session:sign(#{<<"uid">> => 42},
                                     #{secret => Secret, max_age => 3600}),
    Hdr = livery_auth_session:set_cookie_header(Value,
                                                #{max_age => 3600}),
    R = livery_resp:redirect(303, <<"/">>),
    livery_resp:with_header(element(1, Hdr), element(2, Hdr), R).
```
""".
-behaviour(livery_middleware).

-export([call/3]).
-export([sign/2, verify/2, set_cookie_header/2, clear_cookie_header/1]).

-export_type([error_reason/0]).

-type error_reason() :: malformed | bad_signature | expired.

%%====================================================================
%% Middleware
%%====================================================================

-spec call(livery_req:req(), livery_middleware:next(), map()) ->
    livery_resp:resp().
call(Req, Next, State) ->
    case livery_ext:cookie(name(State), Req) of
        undefined ->
            case maps:get(required, State, false) of
                true  -> unauthorized();
                false -> Next(Req)
            end;
        Value ->
            case verify(Value, State) of
                {ok, Data} ->
                    Next(livery_req:set_meta(meta_key(State), Data, Req));
                {error, _} ->
                    unauthorized()
            end
    end.

%%====================================================================
%% Cookie value sign / verify
%%====================================================================

-doc """
Sign a session payload into a cookie value.

`Data` is any JSON-encodable map. With `max_age` (seconds) an `exp`
claim is embedded and enforced by `verify/2`. Returns
`base64url(payload) "." base64url(hmac)`.
""".
-spec sign(map(), map()) -> binary().
sign(Data, Opts) when is_map(Data) ->
    Json = iolist_to_binary(json:encode(add_exp(Data, Opts))),
    P = b64(Json),
    Sig = b64(mac(secret(Opts), Json)),
    <<P/binary, ".", Sig/binary>>.

-doc """
Verify a cookie value and return its payload map.

Checks the HMAC signature in constant time and, if present, the
`exp` claim. Errors: `malformed`, `bad_signature`, `expired`.
""".
-spec verify(binary(), map()) -> {ok, map()} | {error, error_reason()}.
verify(Cookie, Opts) ->
    case binary:split(Cookie, <<".">>) of
        [P, Sig] ->
            case {unb64(P), unb64(Sig)} of
                {{ok, Json}, {ok, Actual}} ->
                    Expected = mac(secret(Opts), Json),
                    case byte_size(Expected) =:= byte_size(Actual)
                        andalso crypto:hash_equals(Expected, Actual) of
                        true  -> decode_payload(Json);
                        false -> {error, bad_signature}
                    end;
                _ ->
                    {error, malformed}
            end;
        _ ->
            {error, malformed}
    end.

%%====================================================================
%% Set-Cookie builders
%%====================================================================

-doc """
Build a `Set-Cookie` header carrying a signed value.

Attributes come from `Opts`: `path` (default `<<"/">>`),
`http_only` (default `true`), `secure` (default `true`),
`same_site` (default `<<"Lax">>`), `max_age`, `domain`.
""".
-spec set_cookie_header(binary(), map()) -> {binary(), binary()}.
set_cookie_header(Value, Opts) ->
    {<<"set-cookie">>,
     iolist_to_binary([name(Opts), <<"=">>, Value, cookie_attrs(Opts)])}.

-doc "Build a `Set-Cookie` header that expires the session cookie.".
-spec clear_cookie_header(map()) -> {binary(), binary()}.
clear_cookie_header(Opts) ->
    {<<"set-cookie">>,
     iolist_to_binary([name(Opts), <<"=; Path=">>, path(Opts),
                       <<"; Max-Age=0">>])}.

%%====================================================================
%% Internals
%%====================================================================

-spec decode_payload(binary()) -> {ok, map()} | {error, error_reason()}.
decode_payload(Json) ->
    try json:decode(Json) of
        Map when is_map(Map) -> check_exp(Map);
        _                    -> {error, malformed}
    catch
        _:_ -> {error, malformed}
    end.

-spec check_exp(map()) -> {ok, map()} | {error, expired}.
check_exp(#{<<"exp">> := Exp} = Map) when is_integer(Exp) ->
    case erlang:system_time(second) =< Exp of
        true  -> {ok, Map};
        false -> {error, expired}
    end;
check_exp(Map) ->
    {ok, Map}.

-spec add_exp(map(), map()) -> map().
add_exp(Data, #{max_age := MaxAge}) when is_integer(MaxAge) ->
    Data#{<<"exp">> => erlang:system_time(second) + MaxAge};
add_exp(Data, _Opts) ->
    Data.

-spec cookie_attrs(map()) -> iodata().
cookie_attrs(Opts) ->
    [<<"; Path=">>, path(Opts),
     domain_attr(Opts),
     max_age_attr(Opts),
     same_site_attr(Opts),
     bool_attr(<<"; Secure">>, maps:get(secure, Opts, true)),
     bool_attr(<<"; HttpOnly">>, maps:get(http_only, Opts, true))].

-spec domain_attr(map()) -> iodata().
domain_attr(#{domain := D}) -> [<<"; Domain=">>, D];
domain_attr(_)              -> [].

-spec max_age_attr(map()) -> iodata().
max_age_attr(#{max_age := M}) when is_integer(M) ->
    [<<"; Max-Age=">>, integer_to_binary(M)];
max_age_attr(_) ->
    [].

-spec same_site_attr(map()) -> iodata().
same_site_attr(Opts) ->
    [<<"; SameSite=">>, maps:get(same_site, Opts, <<"Lax">>)].

-spec bool_attr(binary(), boolean()) -> iodata().
bool_attr(Attr, true) -> Attr;
bool_attr(_Attr, false) -> [].

-spec name(map()) -> binary().
name(Opts) -> maps:get(name, Opts, <<"session">>).

-spec path(map()) -> binary().
path(Opts) -> maps:get(path, Opts, <<"/">>).

-spec meta_key(map()) -> term().
meta_key(Opts) -> maps:get(meta_key, Opts, session).

-spec secret(map()) -> binary().
secret(#{secret := S}) -> S.

-spec mac(binary(), binary()) -> binary().
mac(Secret, Data) ->
    crypto:mac(hmac, sha256, Secret, Data).

-spec b64(binary()) -> binary().
b64(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).

-spec unb64(binary()) -> {ok, binary()} | error.
unb64(Bin) ->
    try
        {ok, base64:decode(Bin, #{mode => urlsafe, padding => false})}
    catch
        _:_ -> error
    end.

-spec unauthorized() -> livery_resp:resp().
unauthorized() ->
    livery_resp:text(401, <<"invalid session">>).
