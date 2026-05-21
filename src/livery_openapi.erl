-module(livery_openapi).
-moduledoc """
OpenAPI 3.1 document generation from route metadata.

`build/1` turns a list of routes into an OpenAPI 3.1 document
(a JSON-encodable map). Each route is
`{Method, Path, Handler}` or `{Method, Path, Handler, Meta}`; the
optional `Meta` map carries operation-level fields:

```erlang
#{
    operation_id => binary(),
    summary      => binary(),
    description  => binary(),
    tags         => [binary()],
    parameters   => [map()],   %% extra (non-path) parameters
    request_body => map(),     %% OpenAPI requestBody object
    responses    => #{100..599 | binary() => map()}
}
```

Livery path templates (`:param`, `*wildcard`) are rewritten to
OpenAPI's `{param}` form, and a `path` parameter is synthesised for
each captured segment.

```erlang
Doc = livery_openapi:build(#{
    info   => #{title => <<"My API">>, version => <<"1.0.0">>},
    routes => [
        {<<"GET">>, <<"/users/:id">>, {users, show},
         #{summary => <<"Fetch a user">>,
           responses => #{200 => #{description => <<"the user">>}}}}
    ]
}),
JsonBytes = livery_openapi:to_json(Doc).
```

`handler/1` returns a Livery handler that serves the document as
`application/json`; mount it at `/openapi.json`.
""".

-export([
    build/1,
    to_json/1,
    handler/1,
    redoc_handler/0,
    redoc_handler/1,
    swagger_ui_handler/0,
    swagger_ui_handler/1
]).

-export_type([build_opts/0, route/0, document/0]).

-type route() ::
    {binary(), binary(), term()}
    | {binary(), binary(), term(), map()}.

-type build_opts() :: #{
    info := map(),
    routes := [route()],
    servers => [map()]
}.

-type document() :: map().

%%====================================================================
%% Build
%%====================================================================

-doc "Build an OpenAPI 3.1 document map from routes + info.".
-spec build(build_opts()) -> document().
build(Opts) ->
    Info = maps:get(info, Opts, #{
        <<"title">> => <<"API">>,
        <<"version">> => <<"0.0.0">>
    }),
    Routes = maps:get(routes, Opts, []),
    Base = #{
        <<"openapi">> => <<"3.1.0">>,
        <<"info">> => normalize_info(Info),
        <<"paths">> => build_paths(Routes)
    },
    case maps:get(servers, Opts, undefined) of
        undefined -> Base;
        Servers -> Base#{<<"servers">> => Servers}
    end.

-spec normalize_info(map()) -> map().
normalize_info(Info) ->
    Title = get_any([title, <<"title">>], Info, <<"API">>),
    Vsn = get_any([version, <<"version">>], Info, <<"0.0.0">>),
    Extra = maps:without([title, version, <<"title">>, <<"version">>], Info),
    maps:merge(Extra, #{<<"title">> => Title, <<"version">> => Vsn}).

-spec build_paths([route()]) -> map().
build_paths(Routes) ->
    lists:foldl(fun add_route/2, #{}, Routes).

add_route({Method, Path, _Handler}, Acc) ->
    add_route({Method, Path, ignore, #{}}, Acc);
add_route({Method, Path, _Handler, Meta}, Acc) ->
    {Template, PathParams} = template(Path),
    Operation = operation(Meta, PathParams),
    MethodKey = string:lowercase(Method),
    Item0 = maps:get(Template, Acc, #{}),
    Item1 = Item0#{MethodKey => Operation},
    Acc#{Template => Item1}.

%%====================================================================
%% Operation object
%%====================================================================

operation(Meta, PathParams) ->
    Params = PathParams ++ maps:get(parameters, Meta, []),
    Base0 = #{<<"responses">> => responses(maps:get(responses, Meta, default))},
    Base1 = put_opt(<<"operationId">>, maps:get(operation_id, Meta, undefined), Base0),
    Base2 = put_opt(<<"summary">>, maps:get(summary, Meta, undefined), Base1),
    Base3 = put_opt(<<"description">>, maps:get(description, Meta, undefined), Base2),
    Base4 = put_opt(<<"tags">>, maps:get(tags, Meta, undefined), Base3),
    Base5 = put_opt(<<"requestBody">>, maps:get(request_body, Meta, undefined), Base4),
    case Params of
        [] -> Base5;
        _ -> Base5#{<<"parameters">> => Params}
    end.

responses(default) ->
    #{<<"200">> => #{<<"description">> => <<"OK">>}};
responses(Map) when is_map(Map) ->
    maps:fold(
        fun(Status, Resp, Acc) ->
            Acc#{status_key(Status) => normalize_response(Resp)}
        end,
        #{},
        Map
    ).

status_key(S) when is_integer(S) -> integer_to_binary(S);
status_key(S) when is_binary(S) -> S.

normalize_response(Resp) when is_map(Resp) ->
    case maps:is_key(<<"description">>, Resp) orelse maps:is_key(description, Resp) of
        true ->
            rekey_description(Resp);
        false ->
            Resp#{<<"description">> => <<"">>}
    end.

rekey_description(Resp) ->
    case maps:take(description, Resp) of
        {D, Rest} -> Rest#{<<"description">> => D};
        error -> Resp
    end.

%%====================================================================
%% Path templating: /users/:id -> /users/{id}, *rest -> {rest}
%%====================================================================

-spec template(binary()) -> {binary(), [map()]}.
template(Path) ->
    Segments = binary:split(Path, <<"/">>, [global]),
    {OutSegs, Params} = lists:foldr(fun template_segment/2, {[], []}, Segments),
    {join(OutSegs), Params}.

template_segment(<<$:, Name/binary>>, {Segs, Params}) when byte_size(Name) > 0 ->
    {[<<"{", Name/binary, "}">> | Segs], [path_param(Name) | Params]};
template_segment(<<$*, Name/binary>>, {Segs, Params}) when byte_size(Name) > 0 ->
    {[<<"{", Name/binary, "}">> | Segs], [path_param(Name) | Params]};
template_segment(Seg, {Segs, Params}) ->
    {[Seg | Segs], Params}.

path_param(Name) ->
    #{
        <<"name">> => Name,
        <<"in">> => <<"path">>,
        <<"required">> => true,
        <<"schema">> => #{<<"type">> => <<"string">>}
    }.

join([]) ->
    <<"/">>;
join(Segs) ->
    case iolist_to_binary(lists:join(<<"/">>, Segs)) of
        <<>> -> <<"/">>;
        <<"/", _/binary>> = B -> B;
        B -> <<"/", B/binary>>
    end.

%%====================================================================
%% Serialisation + serving
%%====================================================================

-doc "Encode an OpenAPI document to JSON bytes.".
-spec to_json(document()) -> binary().
to_json(Doc) ->
    iolist_to_binary(json:encode(Doc)).

-doc """
Return a Livery handler that serves the given document as
`application/json`. Mount it at `/openapi.json`.
""".
-spec handler(document()) -> fun((livery_req:req()) -> livery_resp:resp()).
handler(Doc) ->
    Body = to_json(Doc),
    fun(_Req) -> livery_resp:json(200, Body) end.

-doc "Redoc UI handler loading the spec from `/openapi.json`.".
-spec redoc_handler() -> fun((livery_req:req()) -> livery_resp:resp()).
redoc_handler() ->
    redoc_handler(<<"/openapi.json">>).

-doc """
Return a Livery handler serving a Redoc documentation page that
loads the OpenAPI spec from `SpecUrl`. Self-contained HTML (the
Redoc bundle is pulled from a CDN); no static files or
`livery_resp:file` support needed.
""".
-spec redoc_handler(binary()) ->
    fun((livery_req:req()) -> livery_resp:resp()).
redoc_handler(SpecUrl) when is_binary(SpecUrl) ->
    Html = redoc_html(SpecUrl),
    fun(_Req) -> livery_resp:html(200, Html) end.

-spec redoc_html(binary()) -> iodata().
redoc_html(SpecUrl) ->
    [
        <<"<!DOCTYPE html><html><head><meta charset=\"utf-8\">">>,
        <<"<title>API documentation</title>">>,
        <<"<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">">>,
        <<"</head><body><redoc spec-url=\"">>,
        SpecUrl,
        <<"\"></redoc>">>,
        <<"<script src=\"https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js\"></script>">>,
        <<"</body></html>">>
    ].

-doc "Swagger UI handler loading the spec from `/openapi.json`.".
-spec swagger_ui_handler() -> fun((livery_req:req()) -> livery_resp:resp()).
swagger_ui_handler() ->
    swagger_ui_handler(<<"/openapi.json">>).

-doc """
Return a Livery handler serving a Swagger UI documentation page
that loads the OpenAPI spec from `SpecUrl`. Self-contained HTML
(the Swagger UI bundle is pulled from a CDN); no static files
needed.
""".
-spec swagger_ui_handler(binary()) ->
    fun((livery_req:req()) -> livery_resp:resp()).
swagger_ui_handler(SpecUrl) when is_binary(SpecUrl) ->
    Html = swagger_ui_html(SpecUrl),
    fun(_Req) -> livery_resp:html(200, Html) end.

-spec swagger_ui_html(binary()) -> iodata().
swagger_ui_html(SpecUrl) ->
    [
        <<"<!DOCTYPE html><html><head><meta charset=\"utf-8\">">>,
        <<"<title>API documentation</title>">>,
        <<"<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">">>,
        <<"<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/swagger-ui-dist/swagger-ui.css\">">>,
        <<"</head><body><div id=\"swagger-ui\"></div>">>,
        <<"<script src=\"https://cdn.jsdelivr.net/npm/swagger-ui-dist/swagger-ui-bundle.js\"></script>">>,
        <<"<script>window.onload=function(){SwaggerUIBundle({url:\"">>,
        SpecUrl,
        <<"\",dom_id:\"#swagger-ui\"});};</script>">>,
        <<"</body></html>">>
    ].

%%====================================================================
%% Helpers
%%====================================================================

put_opt(_Key, undefined, Map) -> Map;
put_opt(Key, Value, Map) -> Map#{Key => Value}.

get_any([], _Map, Default) ->
    Default;
get_any([K | Rest], Map, Default) ->
    case maps:find(K, Map) of
        {ok, V} -> V;
        error -> get_any(Rest, Map, Default)
    end.
