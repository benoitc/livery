%% @doc A tiny adapter you can read in one sitting.
%%
%% The shipped adapters (`livery_h1', `livery_h2', `livery_h3') sit on
%% real wire libraries, which makes them a lot to take in at once. This
%% one keeps the wire out of the way: it captures the response in an ETS
%% table instead of writing to a socket. What it does NOT skip is the
%% interesting part, the per-request worker. A request still spawns a
%% real `livery_req_proc' through `livery_req_sup:start_request/1', the
%% worker runs your middleware and handler, and it drives the response
%% back through `livery:emit/3', which calls the eight callbacks below.
%% So this is a faithful, readable map of how a Livery adapter is wired.
%%
%% Run one request through it:
%%
%%     rebar3 as examples shell
%%     {ok, _} = application:ensure_all_started(livery).
%%     L = livery_example_adapter:start(),
%%     Cap = livery_example_adapter:request(
%%             L, [], fun(_Req) -> livery_resp:text(200, <<"hi">>) end, #{}),
%%     200 = livery_example_adapter:status(Cap),
%%     <<"hi">> = livery_example_adapter:body(Cap),
%%     livery_example_adapter:stop(L).
%%
%% To grow this into a real transport: keep the same callbacks, replace
%% the ETS sink with socket writes, and translate your wire's incoming
%% body events into `{livery_body, Ref, _}' messages to the worker (see
%% the `{h1_stream, _}' loop in `livery_h1'). When it works, add a group
%% to `test/livery_parity_SUITE.erl' so it is held to the same observable
%% behaviour as the others. `livery_test_adapter' is the canonical
%% minimal reference.
-module(livery_example_adapter).
-behaviour(livery_adapter).

-include("livery.hrl").

%% driver
-export([start/0, request/4]).
%% capture accessors
-export([status/1, headers/1, header/2, body/1]).
%% livery_adapter callbacks
-export([
    start/3,
    stop/1,
    send_headers/4,
    send_data/3,
    send_trailers/2,
    reset/2,
    peer_info/1,
    capabilities/1
]).

-record(captured, {
    status :: undefined | 100..599,
    headers = [] :: [{binary(), binary()}],
    body_chunks = [] :: [iodata()],
    trailers :: undefined | [{binary(), binary()}],
    reset :: undefined | term()
}).

-opaque capture() :: #captured{}.
-type listener() :: ets:tid().
-type stream() :: {listener(), reference()}.
-export_type([capture/0, listener/0, stream/0]).

%%====================================================================
%% Driver
%%====================================================================

%% @doc Start an in-memory listener (just the ETS capture table).
-spec start() -> listener().
start() ->
    ets:new(?MODULE, [public, set]).

%% @doc Run one request to completion and return what was emitted.
%%
%% This is the part worth studying. We build a request, hand it to the
%% per-request supervisor, feed the optional body, then wait for the
%% worker to finish. The worker, not us, runs the handler and calls our
%% `send_*' callbacks via `livery:emit/3'. `Spec' is a map of request
%% fields, plus an optional `body_bin' binary.
-spec request(
    listener(),
    livery_middleware:stack(),
    livery_middleware:handler(),
    map()
) -> capture().
request(Listener, Stack, Handler, Spec) ->
    Stream = new_stream(Listener),
    BodyRef = make_ref(),
    Reader = livery_body:new(BodyRef),
    Fields = maps:merge(
        #{protocol => h1, method => <<"GET">>, path => <<"/">>},
        maps:remove(body_bin, Spec)
    ),
    Req0 = livery_req:new(Fields),
    Req = Req0#livery_req{adapter = ?MODULE, stream = Stream, body = {stream, Reader}},
    {ok, Worker} = livery_req_sup:start_request(#{
        adapter => ?MODULE,
        stream => Stream,
        req => Req,
        stack => Stack,
        handler => Handler
    }),
    MRef = erlang:monitor(process, Worker),
    case maps:get(body_bin, Spec, <<>>) of
        <<>> -> ok;
        Bin -> Worker ! {livery_body, BodyRef, {data, Bin}}
    end,
    Worker ! {livery_body, BodyRef, eof},
    receive
        {'DOWN', MRef, process, Worker, _} -> ok
    after 5000 ->
        error(worker_timeout)
    end,
    capture(Stream).

%%====================================================================
%% Capture accessors
%%====================================================================

-spec status(capture()) -> undefined | 100..599.
status(#captured{status = S}) -> S.

-spec headers(capture()) -> [{binary(), binary()}].
headers(#captured{headers = H}) -> H.

-spec header(binary(), capture()) -> binary() | undefined.
header(Name, #captured{headers = H}) ->
    case lists:keyfind(Name, 1, H) of
        {_, V} -> V;
        false -> undefined
    end.

-spec body(capture()) -> binary().
body(#captured{body_chunks = Cs}) ->
    iolist_to_binary(lists:reverse(Cs)).

%%====================================================================
%% livery_adapter callbacks
%%====================================================================

-spec start(atom(), term(), map()) -> {ok, listener()}.
start(_Name, _Spec, _Opts) ->
    {ok, start()}.

-spec stop(listener()) -> ok.
stop(Tab) ->
    ets:delete(Tab),
    ok.

-spec send_headers(
    stream(),
    100..599,
    [{binary(), binary()}],
    livery_adapter:send_opts()
) -> ok.
send_headers({Tab, Ref}, Status, Headers, _Opts) ->
    update(Tab, Ref, fun(C) -> C#captured{status = Status, headers = Headers} end).

-spec send_data(stream(), iodata(), livery_adapter:send_opts()) -> ok.
send_data({Tab, Ref}, IoData, _Opts) ->
    update(Tab, Ref, fun(C) ->
        C#captured{body_chunks = [IoData | C#captured.body_chunks]}
    end).

-spec send_trailers(stream(), [{binary(), binary()}]) -> ok.
send_trailers({Tab, Ref}, Trailers) ->
    update(Tab, Ref, fun(C) -> C#captured{trailers = Trailers} end).

-spec reset(stream(), term()) -> ok.
reset({Tab, Ref}, Reason) ->
    update(Tab, Ref, fun(C) -> C#captured{reset = Reason} end).

-spec peer_info(stream()) -> livery_adapter:peer_info().
peer_info(_Stream) ->
    #{peer => {{127, 0, 0, 1}, 0}, tls => undefined, alpn => undefined}.

-spec capabilities(listener()) -> livery_adapter:capabilities().
capabilities(_) ->
    #{trailers => true, extended_connect => false, datagrams => false, capsules => false}.

%%====================================================================
%% Internals
%%====================================================================

new_stream(Tab) ->
    Ref = make_ref(),
    true = ets:insert(Tab, {Ref, #captured{}}),
    {Tab, Ref}.

capture({Tab, Ref}) ->
    [{_, C}] = ets:lookup(Tab, Ref),
    C.

update(Tab, Ref, F) ->
    [{_, C}] = ets:lookup(Tab, Ref),
    true = ets:insert(Tab, {Ref, F(C)}),
    ok.
