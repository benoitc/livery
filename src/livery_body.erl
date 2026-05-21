-module(livery_body).
-moduledoc """
Streaming request-body reader.

The adapter delivers body chunks, trailers, end-of-body, and reset
notifications as messages to the per-request process:

- `{livery_body, Ref, {data, IoData}}`
- `{livery_body, Ref, {trailers, Headers}}`
- `{livery_body, Ref, eof}`
- `{livery_body, Ref, {reset, Reason}}`

A reader is a small value held by the handler that knows the
stream reference and tracks terminal state. `read/2` returns the
next chunk, blocking on the mailbox up to a caller-supplied
timeout. `read_all/1,2` drains the entire body.

Backpressure is per-chunk: the handler reads one chunk per call,
so the engine can size its windows accordingly. Real demand
signaling lands with the H1 adapter; this module exposes
`signal_demand/2` as the hook.
""".

-export([
    new/0,
    new/1,
    new/2,
    ref/1,
    source/1,
    ended/1,
    trailers/1,
    read/2,
    read_all/1,
    read_all/2,
    discard/1,
    discard/2,
    signal_demand/2
]).

-export_type([reader/0, read_result/0, error_reason/0]).

-record(reader, {
    ref :: reference(),
    source :: pid() | undefined,
    ended = false :: boolean(),
    trailers :: undefined | [{binary(), binary()}],
    error :: undefined | error_reason()
}).

-opaque reader() :: #reader{}.

-type error_reason() ::
    timeout
    | {client_reset, term()}.

-type read_result() ::
    {ok, iodata(), reader()}
    | {done, reader()}
    | {error, error_reason(), reader()}.

%%====================================================================
%% Construction
%%====================================================================

-doc "Reader with a fresh reference and no demand source.".
-spec new() -> reader().
new() ->
    #reader{ref = make_ref()}.

-doc "Reader for the given reference, no demand source.".
-spec new(reference()) -> reader().
new(Ref) when is_reference(Ref) ->
    #reader{ref = Ref}.

-doc "Reader bound to a reference and an adapter source pid.".
-spec new(reference(), pid()) -> reader().
new(Ref, Source) when is_reference(Ref), is_pid(Source) ->
    #reader{ref = Ref, source = Source}.

%%====================================================================
%% Accessors
%%====================================================================

-spec ref(reader()) -> reference().
ref(#reader{ref = R}) -> R.

-spec source(reader()) -> pid() | undefined.
source(#reader{source = S}) -> S.

-spec ended(reader()) -> boolean().
ended(#reader{ended = E}) -> E.

-spec trailers(reader()) -> undefined | [{binary(), binary()}].
trailers(#reader{trailers = T}) -> T.

%%====================================================================
%% Reading
%%====================================================================

-doc "Read one chunk from the body, blocking up to `Timeout`.".
-spec read(reader(), timeout()) -> read_result().
read(#reader{ended = true} = R, _Timeout) ->
    {done, R};
read(#reader{error = E} = R, _Timeout) when E =/= undefined ->
    {error, E, R};
read(#reader{ref = Ref} = R, Timeout) ->
    receive
        {livery_body, Ref, {data, Chunk}} ->
            {ok, Chunk, R};
        {livery_body, Ref, eof} ->
            {done, R#reader{ended = true}};
        {livery_body, Ref, {trailers, Hs}} ->
            {done, R#reader{ended = true, trailers = Hs}};
        {livery_body, Ref, {reset, Reason}} ->
            E = {client_reset, Reason},
            {error, E, R#reader{error = E}}
    after Timeout ->
        {error, timeout, R}
    end.

-doc "Drain the entire body, returning the concatenated bytes.".
-spec read_all(reader()) -> {ok, binary(), reader()} | {error, error_reason(), reader()}.
read_all(R) ->
    read_all(R, 5000).

-doc "`read_all/1` with an explicit per-chunk timeout.".
-spec read_all(reader(), timeout()) ->
    {ok, binary(), reader()} | {error, error_reason(), reader()}.
read_all(R, Timeout) ->
    read_all_loop(R, Timeout, []).

-spec read_all_loop(reader(), timeout(), [iodata()]) ->
    {ok, binary(), reader()} | {error, error_reason(), reader()}.
read_all_loop(R, Timeout, Acc) ->
    case read(R, Timeout) of
        {ok, Chunk, R1} ->
            read_all_loop(R1, Timeout, [Chunk | Acc]);
        {done, R1} ->
            {ok, iolist_to_binary(lists:reverse(Acc)), R1};
        {error, E, R1} ->
            {error, E, R1}
    end.

-doc "Drop the remainder of the body.".
-spec discard(reader()) -> {ok, reader()}.
discard(R) -> discard(R, 1000).

-doc "`discard/1` with an explicit per-chunk timeout.".
-spec discard(reader(), timeout()) -> {ok, reader()}.
discard(R, Timeout) ->
    case read(R, Timeout) of
        {ok, _, R1} -> discard(R1, Timeout);
        {done, R1} -> {ok, R1};
        {error, _, R1} -> {ok, R1}
    end.

%%====================================================================
%% Backpressure hook
%%====================================================================

-doc """
Hint to the adapter that the handler is ready for more bytes.

A no-op when no source pid is registered. Real adapters will
translate this into engine-level demand (h1 read_size, h2 flow
control, h3 receive credit).
""".
-spec signal_demand(reader(), non_neg_integer()) -> ok.
signal_demand(#reader{source = undefined}, _N) ->
    ok;
signal_demand(#reader{source = Pid, ref = Ref}, N) when
    is_pid(Pid), is_integer(N), N >= 0
->
    Pid ! {livery_body_demand, Ref, N},
    ok.
