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
""".
-behaviour(livery_client_adapter).

-export([request/2, read/2]).

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

%%====================================================================
%% Internals
%%====================================================================

%% The connection API is needed when the request body streams or the
%% caller wants to stream the response; otherwise request/5 (which always
%% buffers) is simplest.
conn_flow({stream, _}, _Stream) -> true;
conn_flow(_Body, Stream) -> Stream.

buffered(Method, Url, Headers, Body, Opts) ->
    case hackney:request(Method, Url, Headers, Body, Opts) of
        {ok, Status, RespHeaders, RespBody} ->
            {ok, response(Status, RespHeaders, {full, RespBody})};
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
