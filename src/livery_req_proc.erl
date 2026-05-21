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
    init/2
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
init(Parent, #{
    adapter := Adapter,
    stream := Stream,
    req := Req0,
    stack := Stack,
    handler := Handler
}) ->
    proc_lib:init_ack(Parent, {ok, self()}),
    Req = ensure_started_at(Req0),
    try
        Resp = livery:dispatch(Stack, Handler, Req),
        _ = livery:emit(Adapter, Stream, Resp)
    catch
        Class:Reason:Stack0 ->
            handle_crash(Adapter, Stream, Class, Reason, Stack0)
    end,
    exit(normal).

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
handle_crash(Adapter, Stream, _Class, _Reason, _Stack) ->
    Resp = livery_resp:text(500, <<"internal server error">>),
    _ = livery:emit(Adapter, Stream, Resp),
    ok.
