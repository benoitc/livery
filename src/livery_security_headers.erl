-module(livery_security_headers).
-moduledoc """
Security-headers middleware.

Decorates responses with baseline hardening headers. Configure it as a
stack entry `{livery_security_headers, Config}` where every `Config`
key is optional and a value of `false` disables that header:

- `content_type_options` — `true` (default) sends
  `X-Content-Type-Options: nosniff`.
- `frame_options` — header value, default `<<"DENY">>`.
- `referrer_policy` — header value, default `<<"no-referrer">>`.
- `csp` — `Content-Security-Policy` value, default `false` (off): a
  wrong policy breaks apps, so it is opt-in.
- `hsts` — `#{max_age => Secs, include_subdomains => boolean(),
  preload => boolean()}` (defaults `31536000`, `true`, `false`), or
  `false`. `Strict-Transport-Security` is only emitted on secure
  (HTTPS / TLS) requests; on plain HTTP it is meaningless and skipped.

Each header is set only when the handler did not already set it, so a
handler can override any of them per response.
""".
-behaviour(livery_middleware).

-export([call/3]).

-doc "Add the configured security headers to the downstream response.".
-spec call(livery_req:req(), livery_middleware:next(), map() | undefined) ->
    livery_resp:resp().
call(Req, Next, State) ->
    Cfg = config(State),
    Resp = Next(Req),
    Steps = [
        {<<"x-content-type-options">>, content_type_value(Cfg)},
        {<<"x-frame-options">>, maps:get(frame_options, Cfg)},
        {<<"referrer-policy">>, maps:get(referrer_policy, Cfg)},
        {<<"content-security-policy">>, maps:get(csp, Cfg)},
        {<<"strict-transport-security">>, hsts_value(Req, Cfg)}
    ],
    lists:foldl(
        fun({Name, Value}, Acc) -> maybe_set(Name, Value, Acc) end, Resp, Steps
    ).

%%====================================================================
%% Header application
%%====================================================================

-spec maybe_set(binary(), false | binary(), livery_resp:resp()) ->
    livery_resp:resp().
maybe_set(_Name, false, Resp) ->
    Resp;
maybe_set(Name, Value, Resp) when is_binary(Value) ->
    case lists:keymember(Name, 1, livery_resp:headers(Resp)) of
        true -> Resp;
        false -> livery_resp:with_header(Name, Value, Resp)
    end.

-spec content_type_value(map()) -> false | binary().
content_type_value(Cfg) ->
    case maps:get(content_type_options, Cfg) of
        true -> <<"nosniff">>;
        false -> false
    end.

-spec hsts_value(livery_req:req(), map()) -> false | binary().
hsts_value(Req, Cfg) ->
    case maps:get(hsts, Cfg) of
        false ->
            false;
        Opts when is_map(Opts) ->
            case secure(Req) of
                true -> build_hsts(Opts);
                false -> false
            end
    end.

-spec secure(livery_req:req()) -> boolean().
secure(Req) ->
    livery_req:scheme(Req) =:= <<"https">> orelse
        livery_req:tls(Req) =/= undefined.

-spec build_hsts(map()) -> binary().
build_hsts(Opts) ->
    Max = maps:get(max_age, Opts, 31536000),
    Base = <<"max-age=", (integer_to_binary(Max))/binary>>,
    WithSub =
        case maps:get(include_subdomains, Opts, true) of
            true -> <<Base/binary, "; includeSubDomains">>;
            false -> Base
        end,
    case maps:get(preload, Opts, false) of
        true -> <<WithSub/binary, "; preload">>;
        false -> WithSub
    end.

%%====================================================================
%% Config
%%====================================================================

-spec config(map() | undefined) -> map().
config(undefined) ->
    config(#{});
config(State) when is_map(State) ->
    #{
        content_type_options => maps:get(content_type_options, State, true),
        frame_options => maps:get(frame_options, State, <<"DENY">>),
        referrer_policy => maps:get(referrer_policy, State, <<"no-referrer">>),
        hsts => maps:get(hsts, State, default_hsts()),
        csp => maps:get(csp, State, false)
    }.

-spec default_hsts() -> map().
default_hsts() ->
    #{max_age => 31536000, include_subdomains => true, preload => false}.
