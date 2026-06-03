-module(livery_req_proc).
-moduledoc """
Per-request worker.

Spawned by an adapter for every inbound request. Owns the body
reference, runs the middleware stack and handler against the
request value, then drives the response back to the wire through
`livery:emit/3`. If the handler crashes the process maps the
exception to a 500 response so the adapter never sees a half-open
stream.

The proc is plain `proc_lib` rather than `gen_server`: nothing
external commands it during its lifetime except adapter body
messages, which the body reader already drains via the mailbox.
""".

-include("livery.hrl").

-export([
    start_link/1,
    init/2,
    run/1
]).

-export_type([args/0]).

-type args() :: #{
    adapter := module(),
    stream := livery_adapter:stream(),
    req := livery_req:req(),
    stack := livery_middleware:stack(),
    handler := livery_middleware:handler()
}.

-doc "Spawn a per-request worker linked to the caller.".
-spec start_link(args()) -> {ok, pid()}.
start_link(Args) ->
    proc_lib:start_link(?MODULE, init, [self(), Args]).

-doc false.
-spec init(pid(), args()) -> no_return().
init(Parent, Args) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    dispatch(Args),
    exit(normal).

-doc """
Run a request to completion in the calling-spawned process. Used by
`livery_req_sup:start_request/1`, which spawns the worker directly
(no `init_ack` handshake) and monitors it for the in-flight count.
""".
-spec run(args()) -> no_return().
run(Args) ->
    dispatch(Args),
    exit(normal).

-spec dispatch(args()) -> ok.
dispatch(#{
    adapter := Adapter,
    stream := Stream,
    req := Req0,
    stack := Stack,
    handler := Handler
}) ->
    Req = ensure_started_at(Req0),
    try
        Resp = livery:dispatch(Stack, Handler, Req),
        _ = livery:emit(Adapter, Stream, Resp)
    catch
        Class:Reason:Stack0 ->
            handle_crash(Adapter, Stream, Class, Reason, Stack0)
    end,
    ok.

-spec ensure_started_at(livery_req:req()) -> livery_req:req().
ensure_started_at(#livery_req{started_at = undefined} = Req) ->
    Req#livery_req{started_at = erlang:monotonic_time()};
ensure_started_at(Req) ->
    Req.

-spec handle_crash(
    module(),
    livery_adapter:stream(),
    throw | error | exit,
    term(),
    list()
) -> ok.
handle_crash(Adapter, Stream, Class, Reason, Stack) ->
    %% Record the failure server-side (no request body, so no PII leaks
    %% here) while the client only ever sees the generic 500.
    logger:error(#{
        msg => "livery_handler_crash",
        class => Class,
        reason => Reason,
        stacktrace => Stack
    }),
    Resp = livery_resp:text(500, <<"internal server error">>),
    _ = livery:emit(Adapter, Stream, Resp),
    ok.
