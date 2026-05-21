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
-export([bidi_stream_echo/1, datagram_echo/1]).

all() ->
    [bidi_stream_echo, datagram_echo].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(quic),
    {ok, _} = application:ensure_all_started(webtransport),
    {ok, CertDer, KeyDer} = livery_test_certs:load(),
    [{cert, CertDer}, {key, KeyDer} | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    Cert = ?config(cert, Config),
    Key = ?config(key, Config),
    Handler = fun(Req) ->
        livery_wt:upgrade(Req, livery_wt_echo_handler, #{})
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
