%% @doc Migration example: the common Cowboy patterns (a plain handler, a
%% small REST resource, Server-Sent Events, a streaming `cowboy_loop'
%% replacement, and a WebSocket echo) expressed in Livery and served from
%% one handler set. With a TLS/QUIC listener the same handlers serve H2
%% and H3 too.
%%
%%     {ok, Pid} = livery_example_migration:start(8082).
%%     %% curl http://127.0.0.1:8082/plain
%%     %% curl http://127.0.0.1:8082/things
%%     %% curl -XPOST --data '{"name":"x"}' http://127.0.0.1:8082/things
%%     %% curl http://127.0.0.1:8082/events
%%     %% curl http://127.0.0.1:8082/stream
%%     livery_example_migration:stop(Pid).
%%
%% `test/livery_cowboy_parity_SUITE.erl' drives this exact handler set
%% behind both Cowboy and Livery and diffs the observable behaviour.
-module(livery_example_migration).
-behaviour(ws_handler).

%% service
-export([start/0, start/1, stop/1, router/0, handler/0]).
%% route handlers
-export([plain/1, things/1, create_thing/1, thing/1, events/1, stream/1, ws/1]).
%% ws_handler callbacks
-export([init/2, handle_in/2, handle_info/2, terminate/2]).

start() -> start(8082).

start(Port) ->
    livery:start_service(#{
        http => #{port => Port},
        %% livery_access_log is the cowboy_stream access-log replacement.
        middleware => [{livery_access_log, #{}}],
        router => router()
    }).

stop(Pid) ->
    livery:stop_service(Pid).

%% A ready-to-use router-dispatch handler for livery_h1/h2/h3:start/1.
handler() ->
    livery:router_handler(router()).

router() ->
    livery_router:compile([
        {<<"GET">>, <<"/plain">>, {?MODULE, plain}},
        {<<"GET">>, <<"/things">>, {?MODULE, things}},
        {<<"POST">>, <<"/things">>, {?MODULE, create_thing}},
        {<<"GET">>, <<"/things/:id">>, {?MODULE, thing}},
        {<<"GET">>, <<"/events">>, {?MODULE, events}},
        {<<"GET">>, <<"/stream">>, {?MODULE, stream}},
        {<<"GET">>, <<"/ws">>, {?MODULE, ws}}
    ]).

%%====================================================================
%% Route handlers
%%====================================================================

plain(_Req) ->
    livery_resp:text(200, <<"Hello world!">>).

things(_Req) ->
    livery_resp:json(200, <<"[{\"id\":1,\"name\":\"alpha\"}]">>).

create_thing(Req) ->
    %% Read the request body (Livery H1 delivers it as {stream, Reader}),
    %% then return a deterministic created resource that reports how many
    %% bytes were read, so the parity diff proves both servers read it.
    Body = read_body(Req),
    N = integer_to_binary(byte_size(Body)),
    Json = <<"{\"id\":1,\"received\":", N/binary, "}">>,
    Resp = livery_resp:json(201, Json),
    livery_resp:with_header(<<"location">>, <<"/things/1">>, Resp).

thing(Req) ->
    case livery_req:binding(<<"id">>, Req) of
        <<"1">> ->
            livery_resp:json(200, <<"{\"id\":1,\"name\":\"alpha\"}">>);
        _ ->
            livery_resp:json(404, <<"{\"error\":\"not found\"}">>)
    end.

events(_Req) ->
    livery_resp:sse(200, fun(Emit) ->
        _ = [
            Emit(#{event => <<"tick">>, data => integer_to_binary(N)})
         || N <- lists:seq(1, 3)
        ],
        ok
    end).

stream(_Req) ->
    livery_resp:ndjson(200, fun(Emit) ->
        _ = [Emit(#{n => N}) || N <- lists:seq(1, 3)],
        ok
    end).

ws(Req) ->
    livery_ws:upgrade(Req, ?MODULE, #{}).

%%====================================================================
%% Body reading
%%====================================================================

read_body(Req) ->
    case livery_req:body(Req) of
        {stream, Reader} ->
            {ok, Bin, _} = livery_body:read_all(Reader),
            Bin;
        {buffered, IoData} ->
            iolist_to_binary(IoData);
        empty ->
            <<>>
    end.

%%====================================================================
%% ws_handler: plain echo, no readiness frame
%%====================================================================

init(_Req, _Opts) ->
    {ok, undefined}.

handle_in({text, Bin}, State) ->
    {reply, [{text, Bin}], State};
handle_in({binary, Bin}, State) ->
    {reply, [{binary, Bin}], State};
handle_in({ping, Bin}, State) ->
    {reply, [{pong, Bin}], State};
handle_in({close, Code, _Reason}, State) ->
    {stop, {closed, Code}, State};
handle_in(_Frame, State) ->
    {ok, State}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
