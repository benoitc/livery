%% @doc A streaming service you can watch tick.
%%
%% This is the companion code for the "Streaming and backpressure"
%% concept doc. It answers the question that doc exists to answer: where
%% does the producer function live, and what does it look like? Here it
%% is a real top-level function, `tick/3`, that runs inside the
%% per-request worker, loops on `receive`, and pushes one Server-Sent
%% Event per interval until it has sent enough, the client disconnects,
%% or a send fails.
%%
%% Try it:
%%
%%     rebar3 as examples shell
%%     {ok, Pid} = livery_example_stream:start(8080).
%%     curl -N http://127.0.0.1:8080/clock
%%     livery_example_stream:stop(Pid).
%%
%% `curl -N` disables buffering so you see each `event: tick` arrive once
%% a second. Press Ctrl-C and the loop notices the disconnect and stops.
-module(livery_example_stream).

%% service lifecycle
-export([start/0, start/1, stop/1, router/0, handler/0]).
%% route handler
-export([clock/1]).
%% the producer loop, exported so it reads as a real, named function and
%% so tests can drive it with a small count and interval
-export([tick/3]).

start() -> start(8080).

%% @doc Start the streaming service on `Port' over plain HTTP/1.1.
start(Port) ->
    livery:start_service(#{
        http => #{port => Port},
        router => router()
    }).

%% @doc Stop the service.
stop(Pid) ->
    livery:stop_service(Pid).

%% @doc A ready-to-use router-dispatch handler.
handler() ->
    livery:router_handler(router()).

router() ->
    livery_router:compile([
        {<<"GET">>, <<"/clock">>, {?MODULE, clock}}
    ]).

%% The handler does almost nothing: it returns an SSE response whose
%% producer is `tick/3'. Ten ticks, one per second. The producer fun is
%% tiny on purpose; the real work lives in the named function it calls.
clock(_Req) ->
    livery_resp:sse(200, fun(Emit) -> tick(Emit, 10, 1000) end).

%% @doc The producer loop. It runs in the per-request worker, so it is
%% free to block in `receive'. Each pass either sends the next event, or
%% stops because the client went away or the count ran out. Three exits:
%%
%%   - the count reaches zero: a clean, finite stream;
%%   - `{livery_disconnect, _, _}': the client closed, so stop the work;
%%   - `Emit' returns `{error, _}': the send failed, same conclusion.
-spec tick(fun((map()) -> ok | {error, term()}), non_neg_integer(), pos_integer()) -> ok.
tick(_Emit, 0, _Interval) ->
    ok;
tick(Emit, Remaining, Interval) ->
    receive
        {livery_disconnect, _Ref, _Reason} ->
            ok
    after Interval ->
        Now = integer_to_binary(erlang:system_time(second)),
        case Emit(#{event => <<"tick">>, data => Now}) of
            ok -> tick(Emit, Remaining - 1, Interval);
            {error, _} -> ok
        end
    end.
