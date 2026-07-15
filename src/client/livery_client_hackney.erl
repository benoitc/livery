-module(livery_client_hackney).
-moduledoc """
Default client adapter: hackney.

hackney 4.2 speaks HTTP/1.1, HTTP/2, and HTTP/3 (with TLS, pooling, and
IPv6), so this one adapter covers every protocol. The request body may be
buffered (`{full, _}`) or a producer (`{stream, Fun}`); the response is
buffered by default, or streamed (`{stream, Reader}`) when the request
sets `stream => true`.

`Opts` (the client's `adapter_opts`) may carry `hackney => [opt]`, a list
of raw hackney options forwarded verbatim (e.g. `{ssl_options, _}`, a
pool name, HTTP/3 controls like `zero_rtt`/`family`).

hackney's `request/5` always buffers the response, so any request that
either streams its body or wants a streamed response goes through the
connection API (`request` with a `stream` body, `start_response`,
`stream_body`).

Push streaming (`stream/3`, `stream_next/1`, `stop_stream/1`) runs the
request in hackney's async mode (`{async, true | once}`) under a small
relay process that translates hackney's `{hackney_response, _, _}`
messages into Livery's `{livery_response, Ref, _}` messages, folding
hackney's separate `status` and `headers` events into one
`{status, Status, Headers}`. The relay monitors the recipient and tears
the connection down if it dies, so a caller that aborts mid-download
never leaks a connection.
""".
-behaviour(livery_client_adapter).

-export([request/2, read/2, adopt/2]).
-export([stream/3, stream_next/1, stop_stream/1]).

-spec request(livery_client:request(), map()) ->
    {ok, livery_client:response()} | {error, term()}.
request(Req, Opts) ->
    Method = maps:get(method, Req),
    Url = maps:get(url, Req),
    Headers = maps:get(headers, Req, []),
    Timeout = maps:get(timeout, Req, 30000),
    Stream = maps:get(stream, Req, false),
    Body = maps:get(body, Req, empty),
    HackneyOpts = [{recv_timeout, Timeout} | maps:get(hackney, Opts, [])],
    case conn_flow(Body, Stream) of
        false ->
            buffered(Method, Url, Headers, to_body(Body), HackneyOpts);
        true ->
            via_conn(Method, Url, Headers, Body, HackneyOpts, Stream)
    end.

%% Optional callback: pull the next chunk of a streamed response body.
-spec read(term(), timeout()) ->
    {ok, binary(), term()} | {done, term()} | {error, term()}.
read(Conn, _Timeout) ->
    case hackney:stream_body(Conn) of
        {ok, Data} -> {ok, Data, Conn};
        done -> {done, Conn};
        {error, Reason} -> {error, Reason}
    end.

%% Optional callback: hand a streamed connection to a new owner. hackney
%% monitors the owner and tears the connection down when it dies, so a
%% caller that ran the request in a short-lived worker reparents to the
%% process that will read the body. hackney >= 4.6 accepts set_owner while
%% the response body is streaming.
-spec adopt(term(), pid()) -> ok | {error, term()}.
adopt(ConnPid, NewOwner) when is_pid(ConnPid) ->
    hackney_conn:set_owner(ConnPid, NewOwner);
adopt(_State, _NewOwner) ->
    ok.

%% Optional callback: drive the request in a relay process that pushes
%% `{livery_response, Ref, _}` messages to `stream_to`.
-spec stream(livery_client:request(), map(), livery_client_adapter:stream_opts()) ->
    {ok, livery_client_adapter:stream_ref()} | {error, term()}.
stream(#{body := {stream, _}}, _Opts, _StreamOpts) ->
    {error, streaming_request_body_unsupported_in_push_mode};
stream(Req, Opts, #{stream_to := StreamTo} = StreamOpts) ->
    Flow = maps:get(flow, StreamOpts, auto),
    %% Spawn the relay first so the ref can name it, then hand it the ref
    %% and let it open the connection. No hackney message can race ahead
    %% of the ref because the relay only starts once it holds it.
    Relay = spawn(fun() ->
        receive
            {start, Ref} -> relay_start(Ref, Req, Opts, StreamTo, Flow)
        end
    end),
    Ref = {livery_stream, ?MODULE, Relay},
    Relay ! {start, Ref},
    {ok, Ref}.

%% Optional callback: pull one more chunk under `flow => manual`.
-spec stream_next(livery_client_adapter:stream_ref()) -> ok.
stream_next({livery_stream, ?MODULE, Relay}) ->
    Relay ! livery_stream_next,
    ok.

%% Optional callback: cancel a push stream and drop its connection.
-spec stop_stream(livery_client_adapter:stream_ref()) -> ok.
stop_stream({livery_stream, ?MODULE, Relay}) ->
    Relay ! livery_stop_stream,
    ok.

%%====================================================================
%% Internals
%%====================================================================

%% The relay owns the hackney async connection and the monitor on the
%% recipient. It opens the connection in async mode, then loops folding
%% hackney events into Livery messages until done, error, cancel, or the
%% recipient dies.
relay_start(Ref, Req, Opts, StreamTo, Flow) ->
    Method = maps:get(method, Req),
    Url = maps:get(url, Req),
    Headers = maps:get(headers, Req, []),
    Timeout = maps:get(timeout, Req, 30000),
    Body = to_body(maps:get(body, Req, empty)),
    AsyncMode =
        case Flow of
            manual -> once;
            _ -> true
        end,
    Mon = monitor(process, StreamTo),
    HackneyOpts = [
        {recv_timeout, Timeout},
        {async, AsyncMode},
        {stream_to, self()}
        | maps:get(hackney, Opts, [])
    ],
    case hackney:request(Method, Url, Headers, Body, HackneyOpts) of
        {ok, HConn} ->
            relay_loop(#{
                ref => Ref,
                hconn => HConn,
                caller => StreamTo,
                mon => Mon,
                status => undefined
            });
        {error, Reason} ->
            StreamTo ! {livery_response, Ref, {error, Reason}},
            ok
    end.

relay_loop(St) ->
    #{ref := Ref, hconn := HConn, caller := Caller, mon := Mon} = St,
    receive
        {hackney_response, HConn, {status, Code, _Reason}} ->
            relay_loop(St#{status := Code});
        {hackney_response, HConn, {headers, Headers}} ->
            Caller ! {livery_response, Ref, {status, maps:get(status, St), Headers}},
            relay_loop(St);
        {hackney_response, HConn, done} ->
            Caller ! {livery_response, Ref, done},
            ok;
        {hackney_response, HConn, {error, Reason}} ->
            Caller ! {livery_response, Ref, {error, Reason}},
            ok;
        {hackney_response, HConn, {Kind, Location, _Headers}} when
            Kind =:= redirect; Kind =:= see_other
        ->
            %% Push mode does not follow redirects; report where it points.
            Caller ! {livery_response, Ref, {error, {redirect, Location}}},
            ok;
        {hackney_response, HConn, {informational, _Status, _Reason, _Headers}} ->
            relay_loop(St);
        {hackney_response, HConn, Chunk} when is_binary(Chunk) ->
            Caller ! {livery_response, Ref, {chunk, Chunk}},
            relay_loop(St);
        livery_stream_next ->
            _ = hackney:stream_next(HConn),
            relay_loop(St);
        livery_stop_stream ->
            close_quietly(HConn),
            ok;
        {'DOWN', Mon, process, Caller, _Reason} ->
            close_quietly(HConn),
            ok
    end.

close_quietly(HConn) ->
    try
        hackney:close(HConn)
    catch
        _:_ -> ok
    end.

%% The connection API is needed when the request body streams or the
%% caller wants to stream the response; otherwise request/5 (which always
%% buffers) is simplest.
conn_flow({stream, _}, _Stream) -> true;
conn_flow(_Body, Stream) -> Stream.

buffered(Method, Url, Headers, Body, Opts) ->
    case hackney:request(Method, Url, Headers, Body, Opts) of
        {ok, Status, RespHeaders, RespBody} ->
            {ok, response(Status, RespHeaders, {full, RespBody})};
        {ok, Status, RespHeaders} ->
            %% Bodyless response (HEAD, 204, 304): hackney omits the body.
            {ok, response(Status, RespHeaders, {full, <<>>})};
        {error, Reason} ->
            {error, Reason}
    end.

via_conn(Method, Url, Headers, Body, Opts, Stream) ->
    case hackney:request(Method, Url, Headers, stream, Opts) of
        {ok, Conn} ->
            case send_request_body(Conn, Body) of
                ok -> finish(Conn, Stream);
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

send_request_body(Conn, empty) ->
    hackney:finish_send_body(Conn);
send_request_body(Conn, {full, IoData}) ->
    case hackney:send_body(Conn, IoData) of
        ok -> hackney:finish_send_body(Conn);
        {error, Reason} -> {error, Reason}
    end;
send_request_body(Conn, {stream, Producer}) ->
    stream_request_body(Conn, Producer).

stream_request_body(Conn, Producer) ->
    case Producer() of
        eof ->
            hackney:finish_send_body(Conn);
        {ok, Chunk, Next} ->
            case hackney:send_body(Conn, Chunk) of
                ok -> stream_request_body(Conn, Next);
                {error, Reason} -> {error, Reason}
            end
    end.

finish(Conn, Stream) ->
    case hackney:start_response(Conn) of
        {ok, Status, RespHeaders, Conn1} when Stream ->
            {ok, response(Status, RespHeaders, {stream, {?MODULE, Conn1}})};
        {ok, Status, RespHeaders, Conn1} ->
            case hackney:body(Conn1) of
                {ok, Body} -> {ok, response(Status, RespHeaders, {full, Body})};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

to_body(empty) -> <<>>;
to_body({full, IoData}) -> IoData.

response(Status, Headers, Body) ->
    #{status => Status, headers => Headers, body => Body}.
