%% @doc Example Livery service: REST + path params + SSE + NDJSON +
%% an OpenAPI document, all served over HTTP/1.1 on one port.
%%
%% The service dispatches through a compiled `livery_router' passed
%% as the `router' key; path parameters are bound automatically. Run:
%%
%%     {ok, Pid} = livery_example_api:start(8080).
%%     %% curl http://127.0.0.1:8080/
%%     %% curl http://127.0.0.1:8080/hi/ada
%%     %% curl http://127.0.0.1:8080/events
%%     %% curl http://127.0.0.1:8080/openapi.json
%%     livery_example_api:stop(Pid).
-module(livery_example_api).

-export([start/0, start/1, stop/1]).
-export([index/1, greet/1, events/1, ticks/1, openapi/1]).

start() -> start(8080).

start(Port) ->
    livery:start_service(#{
        http       => #{port => Port},
        middleware => [{livery_request_id, undefined},
                       {livery_access_log, #{}}],
        router     => router()
    }).

stop(Pid) ->
    livery:stop_service(Pid).

%% The service dispatches through this router and sets path bindings
%% before invoking each handler.
router() ->
    livery_router:compile([
        {<<"GET">>, <<"/">>,           {?MODULE, index}},
        {<<"GET">>, <<"/hi/:name">>,   {?MODULE, greet}},
        {<<"GET">>, <<"/events">>,     {?MODULE, events}},
        {<<"GET">>, <<"/ticks">>,      {?MODULE, ticks}},
        {<<"GET">>, <<"/openapi.json">>, {?MODULE, openapi}}
    ]).

%%====================================================================
%% Handlers
%%====================================================================

index(_Req) ->
    livery_resp:text(200, <<"hello, world">>).

greet(Req) ->
    Name = livery_req:binding(<<"name">>, Req, <<"stranger">>),
    livery_resp:text(200, [<<"hello, ">>, Name]).

events(_Req) ->
    livery_resp:sse(200, fun(Emit) ->
        [Emit(#{event => <<"tick">>, data => integer_to_binary(N)})
         || N <- lists:seq(1, 5)],
        ok
    end).

ticks(_Req) ->
    livery_resp:ndjson(200, fun(Emit) ->
        [Emit(#{n => N, at => erlang:system_time(second)})
         || N <- lists:seq(1, 5)],
        ok
    end).

openapi(_Req) ->
    Doc = livery_openapi:build(#{
        info   => #{title => <<"Livery Example API">>, version => <<"1.0.0">>},
        routes => [
            {<<"GET">>, <<"/">>, ignore,
             #{summary => <<"Greeting">>,
               responses => #{200 => #{description => <<"a greeting">>}}}},
            {<<"GET">>, <<"/hi/:name">>, ignore,
             #{summary => <<"Greet by name">>,
               responses => #{200 => #{description => <<"a greeting">>}}}},
            {<<"GET">>, <<"/events">>, ignore,
             #{summary => <<"SSE feed">>,
               responses => #{200 => #{description => <<"event stream">>}}}}
        ]
    }),
    livery_resp:json(200, livery_openapi:to_json(Doc)).
