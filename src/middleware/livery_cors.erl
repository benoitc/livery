-module(livery_cors).
-moduledoc """
CORS middleware.

Adds Cross-Origin Resource Sharing headers and answers preflight
`OPTIONS` requests. Configure it as a stack entry
`{livery_cors, Config}` where every `Config` key is optional:

- `origins` — `'*'` (default), a list of allowed origin binaries, or
  a predicate `fun((binary()) -> boolean())`.
- `methods` — allowed methods for preflight `Access-Control-Allow-Methods`
  (default the common verb set).
- `headers` — `mirror` (default, echo the request's
  `Access-Control-Request-Headers`) or an explicit list of header names.
- `expose` — header names for `Access-Control-Expose-Headers` (default `[]`).
- `credentials` — `true` to send `Access-Control-Allow-Credentials`
  (default `false`). With credentials the wildcard origin is never sent;
  the request `Origin` is echoed instead.
- `max_age` — seconds for `Access-Control-Max-Age` on preflights.

`Vary` is set so shared caches stay correct: `Origin` is added on every
branch whenever the emitted headers depend on the request origin (a
list, a predicate, or credentialed wildcard), and
`Access-Control-Request-Headers` is added on mirroring preflights. A
plain non-credentialed `'*'` configuration is origin-independent and
adds no `Vary`.
""".
-behaviour(livery_middleware).

-export([call/3]).

-doc "Apply CORS headers, answering preflight requests directly.".
-spec call(livery_req:req(), livery_middleware:next(), map() | undefined) ->
    livery_resp:resp().
call(Req, Next, State) ->
    Cfg = config(State),
    case livery_req:header(<<"origin">>, Req) of
        undefined ->
            add_actual_vary(Cfg, Next(Req));
        Origin ->
            handle(Req, Next, Cfg, Origin)
    end.

%%====================================================================
%% Request handling
%%====================================================================

-spec handle(livery_req:req(), livery_middleware:next(), map(), binary()) ->
    livery_resp:resp().
handle(Req, Next, Cfg, Origin) ->
    case is_preflight(Req) of
        true -> preflight(Req, Cfg, Origin);
        false -> actual(Req, Next, Cfg, Origin)
    end.

-spec is_preflight(livery_req:req()) -> boolean().
is_preflight(Req) ->
    livery_req:method(Req) =:= <<"OPTIONS">> andalso
        livery_req:has_header(<<"access-control-request-method">>, Req).

-spec preflight(livery_req:req(), map(), binary()) -> livery_resp:resp().
preflight(Req, Cfg, Origin) ->
    Resp0 = livery_resp:empty(204),
    Resp1 =
        case allowed(Origin, maps:get(origins, Cfg)) of
            true -> preflight_headers(Req, Cfg, Origin, Resp0);
            false -> Resp0
        end,
    preflight_vary(Cfg, Resp1).

-spec actual(livery_req:req(), livery_middleware:next(), map(), binary()) ->
    livery_resp:resp().
actual(Req, Next, Cfg, Origin) ->
    Resp0 = Next(Req),
    Resp1 =
        case allowed(Origin, maps:get(origins, Cfg)) of
            true -> actual_headers(Cfg, Origin, Resp0);
            false -> Resp0
        end,
    add_actual_vary(Cfg, Resp1).

%%====================================================================
%% Header builders
%%====================================================================

-spec preflight_headers(livery_req:req(), map(), binary(), livery_resp:resp()) ->
    livery_resp:resp().
preflight_headers(Req, Cfg, Origin, Resp) ->
    R1 = set_acao(Cfg, Origin, Resp),
    R2 = livery_resp:with_header(
        <<"access-control-allow-methods">>, join(maps:get(methods, Cfg)), R1
    ),
    R3 = set_allow_headers(Req, Cfg, R2),
    R4 = set_max_age(Cfg, R3),
    set_credentials(Cfg, R4).

-spec actual_headers(map(), binary(), livery_resp:resp()) -> livery_resp:resp().
actual_headers(Cfg, Origin, Resp) ->
    R1 = set_acao(Cfg, Origin, Resp),
    R2 = set_credentials(Cfg, R1),
    set_expose(Cfg, R2).

-spec set_acao(map(), binary(), livery_resp:resp()) -> livery_resp:resp().
set_acao(Cfg, Origin, Resp) ->
    Value =
        case origin_dependent(Cfg) of
            true -> Origin;
            false -> <<"*">>
        end,
    livery_resp:with_header(<<"access-control-allow-origin">>, Value, Resp).

-spec set_allow_headers(livery_req:req(), map(), livery_resp:resp()) ->
    livery_resp:resp().
set_allow_headers(Req, Cfg, Resp) ->
    case maps:get(headers, Cfg) of
        mirror ->
            case livery_req:header(<<"access-control-request-headers">>, Req) of
                undefined -> Resp;
                Requested -> allow_headers(Requested, Resp)
            end;
        [] ->
            Resp;
        List when is_list(List) ->
            allow_headers(join(List), Resp)
    end.

-spec allow_headers(binary(), livery_resp:resp()) -> livery_resp:resp().
allow_headers(Value, Resp) ->
    livery_resp:with_header(<<"access-control-allow-headers">>, Value, Resp).

-spec set_max_age(map(), livery_resp:resp()) -> livery_resp:resp().
set_max_age(Cfg, Resp) ->
    case maps:get(max_age, Cfg) of
        undefined ->
            Resp;
        Secs when is_integer(Secs), Secs >= 0 ->
            livery_resp:with_header(
                <<"access-control-max-age">>, integer_to_binary(Secs), Resp
            )
    end.

-spec set_credentials(map(), livery_resp:resp()) -> livery_resp:resp().
set_credentials(Cfg, Resp) ->
    case maps:get(credentials, Cfg) of
        true ->
            livery_resp:with_header(
                <<"access-control-allow-credentials">>, <<"true">>, Resp
            );
        false ->
            Resp
    end.

-spec set_expose(map(), livery_resp:resp()) -> livery_resp:resp().
set_expose(Cfg, Resp) ->
    case maps:get(expose, Cfg) of
        [] ->
            Resp;
        List when is_list(List) ->
            livery_resp:with_header(
                <<"access-control-expose-headers">>, join(List), Resp
            )
    end.

%%====================================================================
%% Vary (cache-correctness)
%%====================================================================

-spec add_actual_vary(map(), livery_resp:resp()) -> livery_resp:resp().
add_actual_vary(Cfg, Resp) ->
    case origin_dependent(Cfg) of
        true -> append_vary(<<"Origin">>, Resp);
        false -> Resp
    end.

-spec preflight_vary(map(), livery_resp:resp()) -> livery_resp:resp().
preflight_vary(Cfg, Resp) ->
    R1 = add_actual_vary(Cfg, Resp),
    case maps:get(headers, Cfg) of
        mirror -> append_vary(<<"Access-Control-Request-Headers">>, R1);
        _ -> R1
    end.

-spec append_vary(binary(), livery_resp:resp()) -> livery_resp:resp().
append_vary(Token, Resp) ->
    case vary_present(Token, Resp) of
        true -> Resp;
        false -> livery_resp:append_header(<<"vary">>, Token, Resp)
    end.

-spec vary_present(binary(), livery_resp:resp()) -> boolean().
vary_present(Token, Resp) ->
    LToken = normalize_token(Token),
    Existing = [V || {<<"vary">>, V} <- livery_resp:headers(Resp)],
    lists:any(
        fun(Value) -> lists:member(LToken, split_tokens(Value)) end, Existing
    ).

-spec split_tokens(binary()) -> [binary()].
split_tokens(Value) ->
    [normalize_token(P) || P <- binary:split(Value, <<",">>, [global])].

-spec normalize_token(binary()) -> binary().
normalize_token(Token) ->
    iolist_to_binary(string:trim(string:lowercase(Token))).

%%====================================================================
%% Config and predicates
%%====================================================================

-spec config(map() | undefined) -> map().
config(undefined) ->
    config(#{});
config(State) when is_map(State) ->
    #{
        origins => maps:get(origins, State, '*'),
        methods => maps:get(methods, State, default_methods()),
        headers => maps:get(headers, State, mirror),
        expose => maps:get(expose, State, []),
        credentials => maps:get(credentials, State, false),
        max_age => maps:get(max_age, State, undefined)
    }.

-spec default_methods() -> [binary()].
default_methods() ->
    [
        <<"GET">>,
        <<"HEAD">>,
        <<"PUT">>,
        <<"PATCH">>,
        <<"POST">>,
        <<"DELETE">>,
        <<"QUERY">>,
        <<"OPTIONS">>
    ].

-spec origin_dependent(map()) -> boolean().
origin_dependent(#{origins := '*', credentials := false}) ->
    false;
origin_dependent(_Cfg) ->
    true.

-spec allowed(binary(), '*' | [binary()] | fun((binary()) -> boolean())) ->
    boolean().
allowed(_Origin, '*') ->
    true;
allowed(Origin, List) when is_list(List) ->
    lists:member(Origin, List);
allowed(Origin, Pred) when is_function(Pred, 1) ->
    case Pred(Origin) of
        true -> true;
        _ -> false
    end.

-spec join([binary()]) -> binary().
join(List) ->
    iolist_to_binary(lists:join(<<", ">>, List)).
