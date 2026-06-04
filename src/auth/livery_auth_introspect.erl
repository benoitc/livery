-module(livery_auth_introspect).
-moduledoc """
OAuth 2.0 token introspection middleware (RFC 7662).

Verifies opaque bearer tokens that cannot be checked locally by
POSTing them to the authorization server's introspection endpoint
and trusting the `active` field of the JSON response. On success
the full introspection response (claims such as `scope`,
`client_id`, `username`, `sub`, `exp`) is stored as
`meta(user, _)` (read it back with `livery_ext:user/1`). On any
failure it short-circuits with `401 Unauthorized`.

Use this for reference/opaque tokens; for self-contained JWTs
prefer local verification with `livery_auth_bearer`.

State:

```erlang
{livery_auth_introspect, #{
    endpoint      => <<"https://issuer.example/oauth/introspect">>,
    client_id     => <<"my-api">>,
    client_secret => <<"s3cret">>,
    required      => true
}}
```

`client_id`/`client_secret` authenticate this resource server to
the introspection endpoint via HTTP Basic. The HTTP call is
pluggable via `fetch => fun((Url, Headers, Body) -> {ok, Status,
Body} | {error, _})`; the default uses `hackney`.
""".
-behaviour(livery_middleware).

-export([call/3, introspect/2, default_fetch/3]).

-export_type([opts/0, error_reason/0]).

-type opts() :: #{
    endpoint := binary(),
    client_id => binary(),
    client_secret => binary(),
    token_type_hint => binary(),
    required => boolean(),
    fetch => fetch_fun()
}.

-type fetch_fun() ::
    fun(
        (binary(), [{binary(), binary()}], binary()) ->
            {ok, non_neg_integer(), binary()} | {error, term()}
    ).

-type error_reason() ::
    inactive
    | invalid_response
    | invalid_json
    | {http_status, non_neg_integer()}
    | term().

%%====================================================================
%% Middleware
%%====================================================================

-spec call(livery_req:req(), livery_middleware:next(), map()) ->
    livery_resp:resp().
call(Req, Next, State) ->
    case livery_ext:bearer_token(Req) of
        undefined ->
            case maps:get(required, State, true) of
                true -> unauthorized(<<"missing token">>);
                false -> Next(Req)
            end;
        Token ->
            case introspect(Token, State) of
                {ok, Claims} ->
                    Next(livery_req:set_meta(user, Claims, Req));
                {error, _} ->
                    unauthorized(<<"invalid token">>)
            end
    end.

%%====================================================================
%% Introspection
%%====================================================================

-doc """
Introspect a token at the configured endpoint.

Returns the introspection response map when the token is `active`,
`{error, inactive}` when it is not, and other `{error, _}` reasons
on transport or decoding failure.
""".
-spec introspect(binary(), opts()) -> {ok, map()} | {error, error_reason()}.
introspect(Token, Opts) ->
    Endpoint = maps:get(endpoint, Opts),
    Fetch = maps:get(fetch, Opts, fun default_fetch/3),
    case Fetch(Endpoint, headers(Opts), form_body(Token, Opts)) of
        {ok, 200, Body} -> parse_response(Body);
        {ok, Code, _Body} -> {error, {http_status, Code}};
        {error, _} = Error -> Error
    end.

-spec parse_response(binary()) -> {ok, map()} | {error, error_reason()}.
parse_response(Body) ->
    try json:decode(Body) of
        #{<<"active">> := true} = Claims -> {ok, Claims};
        #{<<"active">> := false} -> {error, inactive};
        _ -> {error, invalid_response}
    catch
        _:_ -> {error, invalid_json}
    end.

-spec form_body(binary(), opts()) -> binary().
form_body(Token, Opts) ->
    Pairs =
        case maps:get(token_type_hint, Opts, undefined) of
            undefined -> [{<<"token">>, Token}];
            Hint -> [{<<"token">>, Token}, {<<"token_type_hint">>, Hint}]
        end,
    iolist_to_binary(uri_string:compose_query(Pairs)).

-spec headers(opts()) -> [{binary(), binary()}].
headers(Opts) ->
    Base = [
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
        {<<"accept">>, <<"application/json">>}
    ],
    case {maps:get(client_id, Opts, undefined), maps:get(client_secret, Opts, undefined)} of
        {Id, Secret} when is_binary(Id), is_binary(Secret) ->
            Cred = base64:encode(<<Id/binary, ":", Secret/binary>>),
            [{<<"authorization">>, <<"Basic ", Cred/binary>>} | Base];
        _ ->
            Base
    end.

%%====================================================================
%% Default HTTP fetcher (hackney)
%%====================================================================

-doc "Default introspection POST using `hackney`, verifying the server's TLS cert.".
-spec default_fetch(binary(), [{binary(), binary()}], binary()) ->
    {ok, non_neg_integer(), binary()} | {error, term()}.
default_fetch(Url, Headers, Body) ->
    {ok, _} = application:ensure_all_started(hackney),
    Opts = [
        with_body,
        {recv_timeout, 5000},
        {connect_timeout, 5000},
        {ssl_options, livery_auth:tls_opts()}
    ],
    case hackney:request(post, Url, Headers, Body, Opts) of
        {ok, Code, _RespHeaders, RespBody} ->
            {ok, Code, RespBody};
        {error, Reason} ->
            {error, Reason}
    end.

%%====================================================================
%% Internals
%%====================================================================

-spec unauthorized(binary()) -> livery_resp:resp().
unauthorized(Detail) ->
    Resp = livery_resp:text(401, Detail),
    livery_resp:with_header(<<"www-authenticate">>, <<"Bearer">>, Resp).
