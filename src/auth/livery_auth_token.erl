-module(livery_auth_token).
-moduledoc """
OAuth 2.0 token endpoint client (RFC 6749 sections 3.2 and 5).

`request/3` asks an authorization server for a token with one of three
grants: `client_credentials` (RFC 6749 4.4), `authorization_code` (4.1,
with the PKCE verifier) and `refresh_token` (6). `livery_client:oauth/1`
and `livery_auth_login` use it; call it directly for anything else.

```erlang
{ok, #{access_token := Token}} = livery_auth_token:request(client_credentials, #{
    scope => <<"orders:read">>
}, #{
    token_endpoint => <<"https://issuer.example/oauth/token">>,
    client_id      => <<"billing">>,
    client_secret  => <<"s3cret">>
}).
```

Client authentication, `client_auth`:

- `client_secret_basic` (default): HTTP Basic, the id and secret
  form-encoded first (RFC 6749 2.3.1);
- `client_secret_post`: id and secret in the form body;
- `private_key_jwt`: a signed assertion (RFC 7523 2.2 as updated by
  RFC 10070), with `private_key => {Alg, Key}` and an optional
  `key_id`. Its `aud` is the server's issuer identifier, given as
  `issuer`, and nothing else; its `typ` is `client-authentication+jwt`;
- `tls_client_auth`: mutual TLS (RFC 8705 2); put the certificate in
  `adapter_opts`, only `client_id` goes in the body;
- `none`: a public client, `client_id` in the body.

Grant parameters: `scope` (binary or list), `resource` (RFC 8707, one or
a list), `code`, `redirect_uri`, `code_verifier`, `refresh_token`, and
`extra` for anything else. The request goes through a plain
`livery_client` built from `adapter` and `adapter_opts`.

The result maps `access_token`, `token_type`, `expires_at` (Unix
seconds, from `expires_in`, or `undefined`), `scope`, `refresh_token`,
`id_token` when present, and `raw` with the whole response. An error
body (RFC 6749 5.2) gives `{error, {oauth_error, Code, Description}}`.

With `dpop => Ctx` (a `livery_client_dpop` context), every request
carries a DPoP proof (RFC 9449 section 5), so the server binds the token
to that key and answers `token_type` `DPoP`; a `use_dpop_nonce` answer
is retried once with the nonce the server sent (section 8). Pushed
authorization requests carry the proof too.

Deviations: `assertion_audience => token_endpoint` puts the token
endpoint in the assertion's `aud`, which RFC 10070 no longer allows,
for servers that still expect it. See AGENTS.md, Known deviations.
""".

-export([request/3, push_request/3]).

-export_type([token/0, opts/0, error_reason/0]).

-define(ASSERTION_TYPE, <<"urn:ietf:params:oauth:client-assertion-type:jwt-bearer">>).

-type token() :: #{
    access_token := binary(),
    token_type := binary(),
    expires_at := integer() | undefined,
    scope => binary(),
    refresh_token => binary(),
    id_token => binary(),
    raw := map()
}.

-type opts() :: #{
    token_endpoint := binary(),
    client_id := binary(),
    client_auth =>
        client_secret_basic | client_secret_post | private_key_jwt | tls_client_auth | none,
    client_secret => binary(),
    private_key => {binary(), term()},
    key_id => binary(),
    issuer => binary(),
    assertion_audience => issuer | token_endpoint,
    adapter => module(),
    adapter_opts => map(),
    timeout => timeout(),
    dpop => livery_client_dpop:ctx(),
    now => integer()
}.

-type error_reason() ::
    {oauth_error, binary(), binary() | undefined}
    | {http_status, non_neg_integer()}
    | invalid_response
    | {missing_option, atom()}
    | term().

-doc "Request a token with `Grant` and its `Params`.".
-spec request(client_credentials | authorization_code | refresh_token, map(), opts()) ->
    {ok, token()} | {error, error_reason()}.
request(Grant, Params, Opts) ->
    request(Grant, Params, Opts, nonce_retry).

%% RFC 9449 section 8: a server that wants a nonce answers 400
%% `use_dpop_nonce' with one; the request is made again, once, from the
%% start, so a client assertion is not sent twice.
request(Grant, Params, Opts, Retry) ->
    case client_auth(Opts) of
        {ok, Headers, AuthForm} ->
            Form = AuthForm ++ grant_form(Grant, Params),
            case post(maps:get(token_endpoint, Opts), Headers, Form, Opts) of
                {ok, 400, RespHeaders, Body} when Retry =:= nonce_retry ->
                    case wants_nonce(Opts, RespHeaders, Body) of
                        true -> request(Grant, Params, Opts, no_retry);
                        false -> response(400, Body, Opts)
                    end;
                {ok, Status, _, Body} ->
                    response(Status, Body, Opts);
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

wants_nonce(#{dpop := _}, Headers, Body) ->
    lists:any(fun({K, _}) -> string:lowercase(K) =:= <<"dpop-nonce">> end, Headers) andalso
        case decode(Body) of
            #{<<"error">> := <<"use_dpop_nonce">>} -> true;
            _ -> false
        end;
wants_nonce(_Opts, _Headers, _Body) ->
    false.

-doc """
Push an authorization request to `Endpoint` (RFC 9126), with the same
client authentication as token requests, and return the `request_uri`
to send the browser with. `Params` are the authorization request
parameters; a `request_uri` among them is dropped, as section 2.1
requires. `expires_in` is in seconds.
""".
-spec push_request(binary(), [{binary(), binary()}], opts()) ->
    {ok, #{request_uri := binary(), expires_in := integer() | undefined}}
    | {error, error_reason()}.
push_request(Endpoint, Params, Opts) ->
    case client_auth(Opts) of
        {ok, Headers, AuthForm} ->
            %% `client_id' is required here (2.1); the client authentication
            %% may already carry it.
            Dup = lists:keymember(<<"client_id">>, 1, AuthForm),
            Form =
                AuthForm ++
                    [
                        P
                     || {K, _} = P <- Params,
                        K =/= <<"request_uri">>,
                        not (Dup andalso K =:= <<"client_id">>)
                    ],
            case post(Endpoint, Headers, Form, Opts) of
                {ok, 201, _, Body} -> pushed(decode(Body));
                {ok, Status, _, Body} -> error_response(Status, Body);
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

pushed(#{<<"request_uri">> := Uri} = Raw) when is_binary(Uri) ->
    In = maps:get(<<"expires_in">>, Raw, undefined),
    {ok, #{request_uri => Uri, expires_in => if_number(In)}};
pushed(_) ->
    {error, invalid_response}.

if_number(N) when is_number(N) -> trunc(N);
if_number(_) -> undefined.

%%====================================================================
%% Request
%%====================================================================

grant_form(client_credentials, P) ->
    [{<<"grant_type">>, <<"client_credentials">>}] ++ common(P);
grant_form(authorization_code, P) ->
    [
        {<<"grant_type">>, <<"authorization_code">>}
        | pairs([code, redirect_uri, code_verifier], P)
    ] ++ common(P);
grant_form(refresh_token, P) ->
    [{<<"grant_type">>, <<"refresh_token">>} | pairs([refresh_token], P)] ++ common(P).

common(P) ->
    scope(maps:get(scope, P, undefined)) ++
        [{<<"resource">>, R} || R <- list(maps:get(resource, P, []))] ++
        [{K, V} || {K, V} <- maps:to_list(maps:get(extra, P, #{}))].

scope(undefined) -> [];
scope(S) when is_binary(S) -> [{<<"scope">>, S}];
scope(L) when is_list(L) -> [{<<"scope">>, iolist_to_binary(lists:join(<<" ">>, L))}].

list(L) when is_list(L) -> L;
list(V) -> [V].

pairs(Keys, P) ->
    [{atom_to_binary(K), V} || K <- Keys, V <- [maps:get(K, P, undefined)], V =/= undefined].

client_auth(#{client_id := Id} = Opts) ->
    case maps:get(client_auth, Opts, client_secret_basic) of
        client_secret_basic ->
            with_secret(Opts, fun(Secret) ->
                Cred = base64:encode(<<(form(Id))/binary, ":", (form(Secret))/binary>>),
                {ok, [{<<"authorization">>, <<"Basic ", Cred/binary>>}], []}
            end);
        client_secret_post ->
            with_secret(Opts, fun(Secret) ->
                {ok, [], [{<<"client_id">>, Id}, {<<"client_secret">>, Secret}]}
            end);
        private_key_jwt ->
            assertion(Opts);
        Method when Method =:= tls_client_auth; Method =:= none ->
            {ok, [], [{<<"client_id">>, Id}]}
    end.

with_secret(#{client_secret := Secret}, Fun) when is_binary(Secret) -> Fun(Secret);
with_secret(_Opts, _Fun) -> {error, {missing_option, client_secret}}.

%% RFC 7523 2.2 and 3, as updated by RFC 10070: the server's issuer
%% identifier is the only audience, and the assertion is explicitly typed.
assertion(#{client_id := Id, private_key := _} = Opts) ->
    Aud =
        case maps:get(assertion_audience, Opts, issuer) of
            token_endpoint -> maps:get(token_endpoint, Opts);
            issuer -> maps:get(issuer, Opts, undefined)
        end,
    case Aud of
        undefined ->
            {error, {missing_option, issuer}};
        _ ->
            {ok, [], [
                {<<"client_id">>, Id},
                {<<"client_assertion_type">>, ?ASSERTION_TYPE},
                {<<"client_assertion">>, assertion_jwt(Id, Aud, Opts)}
            ]}
    end;
assertion(_Opts) ->
    {error, {missing_option, private_key}}.

assertion_jwt(Id, Aud, #{private_key := Key} = Opts) ->
    Now = maps:get(now, Opts, os:system_time(second)),
    Kid = [{<<"kid">>, K} || K <- [maps:get(key_id, Opts, undefined)], K =/= undefined],
    Header = maps:from_list([{<<"typ">>, <<"client-authentication+jwt">>} | Kid]),
    Claims = #{
        <<"iss">> => Id,
        <<"sub">> => Id,
        <<"aud">> => Aud,
        <<"iat">> => Now,
        <<"exp">> => Now + 60,
        <<"jti">> => base64:encode(crypto:strong_rand_bytes(16), #{
            mode => urlsafe, padding => false
        })
    },
    livery_auth_jose:sign(Key, Header, Claims).

form(Value) ->
    iolist_to_binary(uri_string:compose_query([{Value, true}])).

post(Url, Headers, Form, Opts) ->
    Body = iolist_to_binary(uri_string:compose_query(Form)),
    Client = livery_client:new(maps:with([adapter, adapter_opts], Opts)),
    ReqOpts = #{
        headers => [
            {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
            {<<"accept">>, <<"application/json">>}
            | Headers ++ dpop_header(Url, Opts)
        ],
        body => {full, Body},
        timeout => maps:get(timeout, Opts, 10000)
    },
    case livery_client:request(Client, post, Url, ReqOpts) of
        {ok, #{headers := RespHeaders} = Resp} ->
            _ = [livery_client_dpop:remember(Ctx, Url, RespHeaders) || Ctx <- dpop_ctx(Opts)],
            {ok, livery_client:status(Resp), RespHeaders, body(Resp)};
        {error, _} = E ->
            E
    end.

dpop_header(Url, Opts) ->
    [{<<"dpop">>, livery_client_dpop:proof(Ctx, post, Url, undefined)} || Ctx <- dpop_ctx(Opts)].

dpop_ctx(#{dpop := Ctx}) -> [Ctx];
dpop_ctx(_Opts) -> [].

body(Resp) ->
    case livery_client:body(Resp) of
        {full, B} -> iolist_to_binary(B);
        _ -> <<>>
    end.

%%====================================================================
%% Response (RFC 6749 5.1, 5.2)
%%====================================================================

response(200, Body, Opts) ->
    case decode(Body) of
        #{<<"access_token">> := Token, <<"token_type">> := Type} = Raw when
            is_binary(Token), is_binary(Type)
        ->
            Now = maps:get(now, Opts, os:system_time(second)),
            Base = #{
                access_token => Token,
                token_type => Type,
                expires_at => expires_at(maps:get(<<"expires_in">>, Raw, undefined), Now),
                raw => Raw
            },
            {ok, maps:merge(Base, optional(Raw))};
        _ ->
            {error, invalid_response}
    end;
response(Status, Body, _Opts) ->
    error_response(Status, Body).

error_response(Status, Body) ->
    case decode(Body) of
        #{<<"error">> := Code} = Err when is_binary(Code) ->
            {error, {oauth_error, Code, maps:get(<<"error_description">>, Err, undefined)}};
        _ ->
            {error, {http_status, Status}}
    end.

decode(Body) ->
    try
        json:decode(Body)
    catch
        _:_ -> undefined
    end.

expires_at(In, Now) when is_number(In) -> Now + trunc(In);
expires_at(_, _Now) -> undefined.

optional(Raw) ->
    maps:from_list([
        {K, V}
     || {Bin, K} <- [
            {<<"scope">>, scope}, {<<"refresh_token">>, refresh_token}, {<<"id_token">>, id_token}
        ],
        V <- [maps:get(Bin, Raw, undefined)],
        is_binary(V)
    ]).
