%% @doc End-to-end WebTransport suite over Livery's H3 adapter.
%%
%% Proves a real WebTransport session takeover: a Livery H3 listener
%% (started with `webtransport:h3_settings/0' merged in) routes an
%% extended-CONNECT request through `livery_wt:upgrade/3', and the
%% `webtransport' client opens a bidi stream and sends a datagram,
%% both echoed back by `livery_wt_echo_handler'.
-module(livery_wt_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    bidi_stream_echo/1,
    datagram_echo/1,
    draft15_protocol_passthrough/1,
    service_serves_h3_and_h2/1
]).

all() ->
    [
        bidi_stream_echo,
        datagram_echo,
        draft15_protocol_passthrough,
        service_serves_h3_and_h2
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(h2),
    {ok, _} = application:ensure_all_started(quic),
    {ok, _} = application:ensure_all_started(webtransport),
    {ok, CertDer, KeyDer} = livery_test_certs:load(),
    [{cert, CertDer}, {key, KeyDer} | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    Cert = ?config(cert, Config),
    Key = ?config(key, Config),
    %% The echo handler reports the request it was accepted with to this
    %% process (init_per_testcase and the case share one process in CT).
    Owner = self(),
    Handler = fun(Req) ->
        livery_wt:upgrade(Req, livery_wt_echo_handler, #{handler_opts => #{owner => Owner}})
    end,
    Opts = maps:merge(webtransport:h3_settings(), #{
        port => 0,
        cert => Cert,
        key => Key,
        stack => [],
        handler => Handler
    }),
    {ok, Listener} = livery_h3:start(Opts),
    {ok, Port} = quic:get_server_port(Listener),
    {ok, Session} = webtransport:connect(
        "localhost",
        Port,
        <<"/wt">>,
        #{transport => h3, verify => verify_none}
    ),
    [{listener, Listener}, {session, Session} | Config].

end_per_testcase(_TC, Config) ->
    catch webtransport:close_session(?config(session, Config)),
    catch livery_h3:stop(?config(listener, Config)),
    ok.

%%====================================================================
%% Cases
%%====================================================================

bidi_stream_echo(Config) ->
    Session = ?config(session, Config),
    {ok, StreamId} = webtransport:open_stream(Session, bidi),
    Data = <<"hello, webtransport over livery">>,
    ok = webtransport:send(Session, StreamId, Data, fin),
    Echo = recv_stream_echo(Session, 5000),
    ?assertEqual(Data, Echo).

datagram_echo(Config) ->
    Session = ?config(session, Config),
    ok = webtransport:send_datagram(Session, <<"ping">>),
    receive
        {webtransport, Session, {datagram, D}} ->
            ?assertEqual(<<"ping">>, D)
    after 5000 ->
        ct:fail(no_datagram_echo)
    end.

%% A draft-15 client sends `:protocol = webtransport-h3'. The adapter
%% used to overwrite it with the draft-02 spelling, which made the
%% `webtransport' library treat every livery session as legacy. The
%% handler must now see the client's value, exactly once.
draft15_protocol_passthrough(_Config) ->
    Request =
        receive
            {wt_request, _Pid, R} -> R
        after 5000 ->
            ct:fail(no_wt_request)
        end,
    Headers = maps:get(headers, Request),
    ?assertEqual([<<"webtransport-h3">>],
                 [V || {<<":protocol">>, V} <- Headers]),
    ?assertEqual(1, length([N || {<<":", _/binary>> = N, _} <- Headers,
                                 N =:= <<":method">>])).

%% One `livery:start_service/1' with the WebTransport settings merged into
%% both the `http3' and the `https' listener serves sessions on each, and a
%% 1 MiB payload comes back whole on both transports (on h2 that payload
%% crosses ~64 DATA frames, which the capsule reader must reassemble).
service_serves_h3_and_h2(Config) ->
    %% The h2 client connection is linked to this process and exits with
    %% `{shutdown, ssl_closed}' when the service stops; trap it so the
    %% teardown is not killed by that signal.
    process_flag(trap_exit, true),
    {CertFile, KeyFile} = livery_test_certs:paths(),
    Handler = fun(Req) ->
        livery_wt:upgrade(Req, livery_wt_echo_handler, #{})
    end,
    {ok, Pid} = livery:start_service(#{
        https => maps:merge(webtransport:h2_settings(), #{
            port => 0, cert => CertFile, key => KeyFile
        }),
        http3 => maps:merge(webtransport:h3_settings(), #{
            port => 0, cert => ?config(cert, Config), key => ?config(key, Config)
        }),
        handler => Handler
    }),
    try
        #{h2 := [TlsPort], h3 := [UdpPort]} = livery:which_listeners(Pid),
        Payload = crypto:strong_rand_bytes(1024 * 1024),
        lists:foreach(
            fun({Transport, Port}) ->
                {ok, Session} = webtransport:connect(
                    "localhost", Port, <<"/wt">>,
                    #{transport => Transport, verify => verify_none}
                ),
                {ok, StreamId} = webtransport:open_stream(Session, bidi),
                ok = webtransport:send(Session, StreamId, Payload, fin),
                Echo = recv_stream_echo(Session, 20000),
                %% The echo handler sends each chunk back as it arrives, then
                %% the whole payload at FIN: Echo = <prefix of Payload> ++ Payload.
                Size = byte_size(Payload),
                PrefixLen = byte_size(Echo) - Size,
                ?assert(PrefixLen >= 0, {Transport, byte_size(Echo)}),
                ?assertEqual(Payload, binary:part(Echo, PrefixLen, Size)),
                ok = webtransport:close_session(Session)
            end,
            [{h3, UdpPort}, {h2, TlsPort}]
        )
    after
        livery:stop_service(Pid)
    end.

%%====================================================================
%% Helpers
%%====================================================================

%% The echo handler may deliver the bidi echo as a stream chunk and/or
%% a stream_fin; accumulate until we have a fin.
recv_stream_echo(Session, Timeout) ->
    recv_stream_echo(Session, Timeout, <<>>).

recv_stream_echo(Session, Timeout, Acc) ->
    receive
        {webtransport, Session, {stream_fin, _SId, bidi, Data}} ->
            <<Acc/binary, Data/binary>>;
        {webtransport, Session, {stream, _SId, bidi, Data}} ->
            recv_stream_echo(Session, Timeout, <<Acc/binary, Data/binary>>)
    after Timeout ->
        ct:fail({no_stream_echo, Acc})
    end.
