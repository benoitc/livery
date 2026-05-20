-module(livery_test_adapter).
-moduledoc """
In-memory adapter used by tests and the parity suite.

Implements `livery_adapter` against an ETS-backed capture store
instead of a real socket. Callers can build a synthetic request,
run a middleware stack and handler against it, and inspect the
emitted status, headers, body chunks, and trailers without
touching a wire.

Response emission is delegated to `livery:emit/3`, the shared
walker that every adapter calls back into.
""".

-behaviour(livery_adapter).

-include("livery.hrl").

%% Public test helpers
-export([
    start/0,
    stop/1,
    new_stream/1,
    new_stream/2,
    feed_body/3,
    capture/1,
    status/1,
    headers/1,
    header/2,
    body/1,
    body_chunks/1,
    trailers/1,
    reset_reason/1,
    end_stream/1,
    run/3,
    run/4
]).

%% livery_adapter callbacks (stop/1 is shared with the public helper above)
-export([
    start/3,
    send_headers/4,
    send_data/3,
    send_trailers/2,
    reset/2,
    peer_info/1,
    capabilities/1
]).

-export_type([listener/0, stream/0, capture/0]).

-record(captured, {
    status :: undefined | 100..599,
    headers = [] :: [{binary(), binary()}],
    body_chunks = [] :: [iodata()],
    end_stream = false :: boolean(),
    trailers :: undefined | [{binary(), binary()}],
    reset :: undefined | term()
}).

-type listener() :: ets:tid().
-type stream() :: {listener(), reference()}.
-opaque capture() :: #captured{}.

%%====================================================================
%% Public test helpers
%%====================================================================

-spec start() -> listener().
start() ->
    ets:new(?MODULE, [public, set]).

-spec stop(listener()) -> ok.
stop(Tab) ->
    ets:delete(Tab),
    ok.

-spec new_stream(listener()) -> stream().
new_stream(Tab) ->
    new_stream(Tab, #{}).

-spec new_stream(listener(), map()) -> stream().
new_stream(Tab, _Meta) ->
    Ref = make_ref(),
    true = ets:insert(Tab, {Ref, #captured{}}),
    {Tab, Ref}.

-doc """
Push a body chunk (or terminal marker) into the per-request
process mailbox in the `livery_body` protocol.
""".
-spec feed_body(reference(), pid(),
                {data, iodata()}
              | {trailers, [{binary(), binary()}]}
              | eof
              | {reset, term()}) -> ok.
feed_body(Ref, Pid, Event) ->
    Pid ! {livery_body, Ref, Event},
    ok.

-spec capture(stream()) -> capture() | undefined.
capture({Tab, Ref}) ->
    case ets:lookup(Tab, Ref) of
        [{_, C}] -> C;
        []       -> undefined
    end.

-spec status(capture()) -> undefined | 100..599.
status(#captured{status = S}) -> S.

-spec headers(capture()) -> [{binary(), binary()}].
headers(#captured{headers = H}) -> H.

-spec header(binary(), capture()) -> binary() | undefined.
header(Name, #captured{headers = H}) ->
    case lists:keyfind(Name, 1, H) of
        {_, V} -> V;
        false  -> undefined
    end.

-spec body(capture()) -> binary().
body(#captured{body_chunks = Cs}) ->
    iolist_to_binary(lists:reverse(Cs)).

-spec body_chunks(capture()) -> [iodata()].
body_chunks(#captured{body_chunks = Cs}) ->
    lists:reverse(Cs).

-spec trailers(capture()) -> undefined | [{binary(), binary()}].
trailers(#captured{trailers = T}) -> T.

-spec reset_reason(capture()) -> undefined | term().
reset_reason(#captured{reset = R}) -> R.

-spec end_stream(capture()) -> boolean().
end_stream(#captured{end_stream = E}) -> E.

-doc """
Drive a request through a middleware stack and handler.

`Spec` is a map of `#livery_req{}` fields. Returns the captured
response. Listener lifecycle is managed for the caller.
""".
-spec run(livery_middleware:stack(), livery_middleware:handler(),
          map()) -> capture().
run(Stack, Handler, Spec) ->
    run(Stack, Handler, Spec, #{}).

-spec run(livery_middleware:stack(), livery_middleware:handler(),
          map(), map()) -> capture().
run(Stack, Handler, Spec, Opts) ->
    Tab = start(),
    try
        Stream = new_stream(Tab),
        Req = build_req(Spec, Stream, Opts),
        Resp = try
            livery:dispatch(Stack, Handler, Req)
        catch
            _Class:_Reason:_St ->
                livery_resp:text(500, <<"internal server error">>)
        end,
        _ = livery:emit(?MODULE, Stream, Resp),
        capture(Stream)
    after
        stop(Tab)
    end.

%%====================================================================
%% livery_adapter callbacks
%%====================================================================

-spec start(atom(), term(), map()) -> {ok, listener()}.
start(_Name, _Spec, _Opts) ->
    {ok, start()}.

-spec send_headers(stream(), 100..599,
                   [{binary(), binary()}],
                   livery_adapter:send_opts()) -> ok.
send_headers({Tab, Ref}, Status, Headers, Opts) ->
    update(Tab, Ref, fun(C) ->
        C#captured{
            status = Status,
            headers = Headers,
            end_stream = maps:get(end_stream, Opts, false) orelse C#captured.end_stream
        }
    end).

-spec send_data(stream(), iodata(), livery_adapter:send_opts()) -> ok.
send_data({Tab, Ref}, IoData, Opts) ->
    update(Tab, Ref, fun(C) ->
        C#captured{
            body_chunks = [IoData | C#captured.body_chunks],
            end_stream = maps:get(end_stream, Opts, false) orelse C#captured.end_stream
        }
    end).

-spec send_trailers(stream(), [{binary(), binary()}]) -> ok.
send_trailers({Tab, Ref}, Trailers) ->
    update(Tab, Ref, fun(C) ->
        C#captured{trailers = Trailers, end_stream = true}
    end).

-spec reset(stream(), term()) -> ok.
reset({Tab, Ref}, Reason) ->
    update(Tab, Ref, fun(C) -> C#captured{reset = Reason} end).

-spec peer_info(stream()) -> livery_adapter:peer_info().
peer_info(_Stream) ->
    #{peer => {{127, 0, 0, 1}, 0}, tls => undefined, alpn => undefined}.

-spec capabilities(listener()) -> livery_adapter:capabilities().
capabilities(_) ->
    #{trailers => true,
      extended_connect => true,
      datagrams => false,
      capsules => false}.

%%====================================================================
%% Internals
%%====================================================================

-spec build_req(map(), stream(), map()) -> livery_req:req().
build_req(Spec, Stream, _Opts) ->
    Defaults = #{
        protocol => h1,
        method => <<"GET">>,
        path => <<"/">>
    },
    Fields = maps:merge(Defaults, Spec),
    Req = livery_req:new(Fields),
    Req#livery_req{adapter = ?MODULE, stream = Stream}.

-spec update(listener(), reference(), fun((#captured{}) -> #captured{})) -> ok.
update(Tab, Ref, F) ->
    [{_, C}] = ets:lookup(Tab, Ref),
    true = ets:insert(Tab, {Ref, F(C)}),
    ok.
