-module(livery_translator).
-moduledoc """
The per-request translator shared by the HTTP adapters.

Every wire library (`h1`, `h2`, `quic_h3`) runs Livery's handler fun in
a process of its own for each request, and sends that request's body,
trailers and resets to it in the library's own message format. This
module turns that process into the request's translator:

- it starts the request worker (`livery_req_proc`), which runs the
  middleware and the handler;
- it turns the library's events into the `{livery_body, Ref, _}`
  messages `livery_body` reads in the worker, so neither the body reader
  nor the handler ever sees a protocol-specific message;
- it enforces the listener's `max_body` before the bytes reach the
  worker's mailbox;
- it notices a disconnect (stream reset or connection gone) while the
  worker is busy in user code, and tells it (`livery_disconnect`).

It runs until the worker exits. An adapter builds the request,
registers the stream with its library if the library needs that, and
calls `serve/2` with:

- `tag` and `key`: the first two elements of the library's
  `{Tag, Key, Event}` messages for this request (`h1_stream` and the
  stream id on H1; `h2` or `quic_h3` and the connection on H2 and H3);
- `classify`: turns `Event` into `{data, Chunk, Fin}`,
  `{trailers, Headers}`, `{reset, Reason}` or `ignore`;
- `conn`: the connection process, watched for a disconnect;
- `on_abandoned`: what to do if the worker finishes while the client is
  still sending a body over `max_body`, or `none`.

You do not call it directly.
""".

-include("livery.hrl").

-export([serve/2, translate/2, split_query/1]).

-export_type([event/0, opts/0, wire/0]).

-type event() ::
    {data, binary(), boolean()}
    | {trailers, [{binary(), binary()}]}
    | {reset, term()}
    | ignore.

-type wire() :: #{
    tag := atom(),
    key := term(),
    classify := fun((term()) -> event()),
    conn := pid(),
    on_abandoned := none | fun(() -> term())
}.

-type opts() :: #{
    adapter := module(),
    stream := livery_adapter:stream(),
    stack := livery_middleware:stack(),
    handler := livery_middleware:handler(),
    max_body := non_neg_integer() | infinity,
    config := term(),
    raw_query := binary(),
    wire := wire(),
    %% Anything else an adapter keeps in its context is ignored.
    atom() => term()
}.

%% `body': under the limit, the bytes forwarded so far; `dropping' once
%% the limit is crossed while the client is still sending; `dropped' once
%% the client has finished too.
-record(t, {
    worker :: pid(),
    wmref :: reference(),
    cmref :: reference(),
    body_ref :: reference(),
    disc_ref :: reference(),
    max :: non_neg_integer() | infinity,
    body = {accepting, 0} :: {accepting, non_neg_integer()} | dropping | dropped,
    callbacks = [] :: [fun(() -> term())],
    fired = false :: boolean(),
    wire :: wire()
}).

-type state() :: #t{}.

-doc """
Start the worker for `Req` and translate until it exits. Answers `503`
through the adapter when the request limit refuses it.
""".
-spec serve(livery_req:req(), opts()) -> ok.
serve(Req, #{adapter := Adapter, stream := Stream, wire := Wire} = Opts) ->
    BodyRef = make_ref(),
    DiscRef = make_ref(),
    Req1 = Req#livery_req{
        body = {stream, livery_body:new(BodyRef)},
        raw_query = maps:get(raw_query, Opts),
        notifier_pid = self(),
        disc_ref = DiscRef,
        config = maps:get(config, Opts)
    },
    Started = livery_req_sup:start_request(#{
        adapter => Adapter,
        stream => Stream,
        req => Req1,
        stack => maps:get(stack, Opts),
        handler => maps:get(handler, Opts)
    }),
    case Started of
        {ok, Worker} ->
            translate(Worker, #{
                body_ref => BodyRef,
                disc_ref => DiscRef,
                max_body => maps:get(max_body, Opts),
                wire => Wire
            });
        {error, _} ->
            overloaded(Adapter, Stream)
    end.

-doc """
Translate for `Worker` until it exits. `serve/2` calls it once the worker
is started; it is exported for the unit tests.
""".
-spec translate(pid(), #{
    body_ref := reference(),
    disc_ref := reference(),
    max_body := non_neg_integer() | infinity,
    wire := wire()
}) -> ok.
translate(Worker, #{body_ref := BodyRef, disc_ref := DiscRef, max_body := Max, wire := Wire}) ->
    loop(#t{
        worker = Worker,
        wmref = erlang:monitor(process, Worker),
        cmref = erlang:monitor(process, maps:get(conn, Wire)),
        body_ref = BodyRef,
        disc_ref = DiscRef,
        max = Max,
        wire = Wire
    }).

-doc "Split a request target into its path and its query string.".
-spec split_query(binary()) -> {binary(), binary()}.
split_query(Path) ->
    case binary:split(Path, <<"?">>) of
        [P, Q] -> {P, Q};
        [P] -> {P, <<>>}
    end.

%%====================================================================
%% Loop
%%====================================================================

-spec loop(state()) -> ok.
loop(
    #t{
        worker = Worker,
        wmref = WMRef,
        cmref = CMRef,
        disc_ref = DiscRef,
        wire = #{tag := Tag, key := Key, classify := Classify, conn := Conn}
    } = T
) ->
    receive
        {Tag, Key, Event} ->
            loop(event(Classify(Event), T));
        {'DOWN', CMRef, process, Conn, Reason} ->
            %% Connection gone: the client left. Keep looping, to serve
            %% callbacks registered late, until the worker exits.
            loop(fire(T, {connection_closed, Reason}));
        {livery_local_reset, DiscRef} ->
            %% The worker is resetting the stream itself (see
            %% livery_disconnect:local_reset/0); its echo is not a disconnect.
            loop(T#t{fired = true});
        {livery_on_disconnect, DiscRef, Fun} ->
            loop(T#t{callbacks = livery_disconnect:register(T#t.fired, Fun, T#t.callbacks)});
        {'DOWN', WMRef, process, Worker, _Reason} ->
            abandoned(T)
    end.

-spec event(event(), state()) -> state().
event({data, _Chunk, Fin}, #t{body = dropping} = T) ->
    T#t{body = dropped_after(Fin)};
event({data, _Chunk, _Fin}, #t{body = dropped} = T) ->
    T;
event({data, <<>>, true}, T) ->
    send(T, eof),
    T;
event({data, Chunk, Fin}, #t{body = {accepting, Bytes}, max = Max} = T) ->
    case livery_body:account(Bytes, Chunk, Max) of
        {ok, Bytes1} ->
            send(T, {data, Chunk}),
            Fin andalso send(T, eof),
            T#t{body = {accepting, Bytes1}};
        over ->
            %% The stream is not reset here, so the handler's 413 reaches
            %% the client; the rest of the body is dropped.
            send(T, {error, body_too_large}),
            T#t{body = dropped_after(Fin)}
    end;
event({trailers, Headers}, T) ->
    send(T, {trailers, Headers}),
    T;
event({reset, Reason}, T) ->
    send(T, {reset, Reason}),
    fire(T, Reason);
event(ignore, T) ->
    T.

-spec dropped_after(boolean()) -> dropping | dropped.
dropped_after(true) -> dropped;
dropped_after(false) -> dropping.

-spec send(state(), term()) -> true.
send(#t{worker = Worker, body_ref = BodyRef}, Msg) ->
    Worker ! {livery_body, BodyRef, Msg},
    true.

-spec fire(state(), term()) -> state().
fire(#t{fired = Fired, worker = Worker, disc_ref = DiscRef, callbacks = Cbs} = T, Reason) ->
    T#t{fired = livery_disconnect:fire_once(Fired, Worker, DiscRef, Reason, Cbs)}.

%% The worker is done. If the client is still sending a body over the
%% limit, the adapter tells it to stop.
-spec abandoned(state()) -> ok.
abandoned(#t{body = dropping, wire = #{on_abandoned := OnAbandoned}}) when
    is_function(OnAbandoned, 0)
->
    _ = OnAbandoned(),
    ok;
abandoned(_T) ->
    ok.

%% No worker slot available (the request limit is reached).
-spec overloaded(module(), livery_adapter:stream()) -> ok.
overloaded(Adapter, Stream) ->
    _ = Adapter:send_headers(
        Stream,
        503,
        [{<<"content-type">>, <<"text/plain; charset=utf-8">>}],
        #{end_stream => true}
    ),
    ok.
