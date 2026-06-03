%% @doc A small notes service that shows Livery end to end.
%%
%% This is the companion code for the "Build a complete service"
%% tutorial. We keep a handful of notes in an ETS table and expose them
%% over HTTP: list and filter, create, fetch one, delete. On top of the
%% CRUD we wire a service-wide middleware stack, a per-route middleware,
%% a Server-Sent Events feed, and a WebSocket echo. Everything shares one
%% router, so the same handlers serve H2 and H3 too once you start a
%% TLS/QUIC listener (see `start_tls/1').
%%
%% Try it from a shell:
%%
%%     rebar3 as examples shell
%%     {ok, Pid} = livery_example_complete:start(8080).
%%
%%     curl http://127.0.0.1:8080/notes
%%     curl -XPOST --data '{"text":"buy bread"}' http://127.0.0.1:8080/notes
%%     curl http://127.0.0.1:8080/notes/1
%%     curl -XDELETE http://127.0.0.1:8080/notes/1
%%     curl -N http://127.0.0.1:8080/events
%%     # a WebSocket client to ws://127.0.0.1:8080/ws echoes every frame
%%
%%     livery_example_complete:stop(Pid).
%%
%% The handlers never touch a socket. They take a request value and
%% return a response value, so `test/livery_example_adapter_tests.erl'
%% can drive them with no wire at all.
-module(livery_example_complete).
-behaviour(ws_handler).

%% service lifecycle
-export([start/0, start/1, start_tls/1, stop/1, router/0, handler/0]).
%% route handlers
-export([list_notes/1, create_note/1, show_note/1, delete_note/1, events/1, ws/1]).
%% ws_handler callbacks
-export([init/2, handle_in/2, handle_info/2, terminate/2]).

%% One named ETS table holds the notes plus a sequence counter. A real
%% service would reach for a database; ETS keeps the example to one file.
-define(TABLE, livery_example_notes).
-define(SEQ_KEY, '$seq').

%%====================================================================
%% Service lifecycle
%%====================================================================

start() -> start(8080).

%% @doc Start the notes service on `Port' over plain HTTP/1.1.
start(Port) ->
    ensure_table(),
    livery:start_service(#{
        http => #{port => Port},
        middleware => base_stack(),
        router => router()
    }).

%% @doc Start the same service over H1, H2 (TLS) and H3 (QUIC) at once,
%% sharing one router. We borrow the self-signed certs vendored under
%% `test/certs'; if they are not reachable we fall back to plain HTTP so
%% the example still runs. Never ship these certs to production.
start_tls(Port) ->
    ensure_table(),
    case load_certs() of
        {ok, Cert, Key} ->
            livery:start_service(#{
                http => #{port => Port},
                https => #{port => Port, cert => Cert, key => Key},
                http3 => #{port => Port, cert => Cert, key => Key},
                middleware => base_stack(),
                router => router()
            });
        error ->
            io:format("no certs under test/certs, starting plain HTTP only~n"),
            start(Port)
    end.

%% @doc Stop the service and forget the notes.
stop(Pid) ->
    Result = livery:stop_service(Pid),
    case ets:info(?TABLE) of
        undefined -> ok;
        _ -> ets:delete(?TABLE)
    end,
    Result.

%% @doc A ready-to-use router-dispatch handler, handy if you would
%% rather drive a single adapter with `livery:start_listener/2'.
handler() ->
    livery:router_handler(router()).

%%====================================================================
%% Router
%%====================================================================

%% Static segments, a `:id' parameter, and one route that carries its
%% own middleware under the route Meta. The Meta stack runs only for
%% that route, nested inside the service-wide stack.
router() ->
    livery_router:compile([
        {<<"GET">>, <<"/notes">>, {?MODULE, list_notes}, #{middleware => [list_marker()]}},
        {<<"POST">>, <<"/notes">>, {?MODULE, create_note}},
        {<<"GET">>, <<"/notes/:id">>, {?MODULE, show_note}},
        {<<"DELETE">>, <<"/notes/:id">>, {?MODULE, delete_note}},
        {<<"GET">>, <<"/events">>, {?MODULE, events}},
        {<<"GET">>, <<"/ws">>, {?MODULE, ws}}
    ]).

%%====================================================================
%% Middleware
%%====================================================================

%% The service-wide stack runs for every request, in order: tag the
%% request, log it, cap the body, and time it.
base_stack() ->
    [
        {livery_request_id, undefined},
        {livery_access_log, #{}},
        {livery_body_limit, #{max => 1_048_576}},
        timing()
    ].

%% A middleware is a fun of `(Req, Next)'. We note the time, let the rest
%% of the pipeline run via `Next', then stamp the response. This is the
%% Tower/Axum shape: a continuation over immutable values.
timing() ->
    fun(Req, Next) ->
        Start = erlang:monotonic_time(millisecond),
        Resp = Next(Req),
        Elapsed = erlang:monotonic_time(millisecond) - Start,
        livery_resp:with_header(
            <<"x-response-time-ms">>,
            integer_to_binary(Elapsed),
            Resp
        )
    end.

%% A per-route middleware, attached to `GET /notes' only.
list_marker() ->
    livery_middleware:after_response(
        fun(Resp) -> livery_resp:with_header(<<"x-list">>, <<"notes">>, Resp) end
    ).

%%====================================================================
%% Route handlers
%%====================================================================

%% List every note as a JSON array.
list_notes(_Req) ->
    livery_resp:json(200, json:encode(all_notes())).

%% Create a note from a JSON body like {"text":"..."}. We read the body
%% ourselves because the socket adapters deliver it as a stream.
create_note(Req) ->
    case decode_body(Req) of
        {ok, #{<<"text">> := Text}} when is_binary(Text) ->
            Note = put_note(Text),
            Id = maps:get(<<"id">>, Note),
            Location = <<"/notes/", Id/binary>>,
            Resp = livery_resp:json(201, json:encode(Note)),
            livery_resp:with_header(<<"location">>, Location, Resp);
        {ok, _} ->
            livery_resp:json(422, <<"{\"error\":\"text is required\"}">>);
        {error, _} ->
            livery_resp:json(400, <<"{\"error\":\"invalid json\"}">>)
    end.

%% One note by id, or a 404 when it is gone.
show_note(Req) ->
    Id = livery_req:binding(<<"id">>, Req),
    case find_note(Id) of
        {ok, Note} -> livery_resp:json(200, json:encode(Note));
        error -> livery_resp:json(404, <<"{\"error\":\"not found\"}">>)
    end.

%% Delete a note. We answer 204 whether or not it was there: deleting an
%% absent note is the state the caller asked for.
delete_note(Req) ->
    Id = livery_req:binding(<<"id">>, Req),
    true = ets:match_delete(?TABLE, {Id, '_'}) =/= false,
    livery_resp:empty(204).

%% A Server-Sent Events feed. The producer is handed an `Emit' fun and
%% pushes events until it returns; Livery frames each one on the wire.
events(_Req) ->
    Count = length(all_notes()),
    livery_resp:sse(200, fun(Emit) ->
        _ = [
            Emit(#{event => <<"notes">>, data => integer_to_binary(Count)})
         || _ <- lists:seq(1, 3)
        ],
        ok
    end).

%% Hand the stream to the WebSocket machinery; this module is the
%% `ws_handler'. Works on H1 (Upgrade) and on H2/H3 (extended CONNECT).
ws(Req) ->
    livery_ws:upgrade(Req, ?MODULE, #{}).

%%====================================================================
%% ws_handler: a plain echo
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

%%====================================================================
%% Notes store (ETS)
%%====================================================================

ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ?TABLE = ets:new(?TABLE, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.

put_note(Text) ->
    Id = integer_to_binary(ets:update_counter(?TABLE, ?SEQ_KEY, {2, 1}, {?SEQ_KEY, 0})),
    Note = #{<<"id">> => Id, <<"text">> => Text},
    true = ets:insert(?TABLE, {Id, Note}),
    Note.

find_note(Id) ->
    case ets:lookup(?TABLE, Id) of
        [{_, Note}] -> {ok, Note};
        [] -> error
    end.

all_notes() ->
    [Note || {Key, Note} <- ets:tab2list(?TABLE), Key =/= ?SEQ_KEY].

%%====================================================================
%% Helpers
%%====================================================================

%% The socket adapters deliver the body as `{stream, Reader}', so read it
%% fully before decoding. The in-memory test adapter hands over
%% `{buffered, _}' instead; we accept both.
decode_body(Req) ->
    Bin =
        case livery_req:body(Req) of
            {stream, Reader} ->
                {ok, Data, _} = livery_body:read_all(Reader),
                Data;
            {buffered, IoData} ->
                iolist_to_binary(IoData);
            empty ->
                <<>>
        end,
    try
        {ok, json:decode(Bin)}
    catch
        _:_ -> {error, invalid_json}
    end.

load_certs() ->
    Dir = filename:join([code:lib_dir(livery), "..", "..", "..", "..", "test", "certs"]),
    CertFile = filename:join(Dir, "cert.pem"),
    KeyFile = filename:join(Dir, "key.pem"),
    case {file:read_file(CertFile), file:read_file(KeyFile)} of
        {{ok, CertPem}, {ok, KeyPem}} ->
            [{'Certificate', CertDer, _}] = public_key:pem_decode(CertPem),
            [{KeyType, KeyDer, _} | _] = public_key:pem_decode(KeyPem),
            {ok, CertDer, public_key:der_decode(KeyType, KeyDer)};
        _ ->
            error
    end.
