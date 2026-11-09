-module(livery_tls_tests).

-include_lib("eunit/include/eunit.hrl").

no_certificate_test() ->
    ?assertEqual(#{verified => false}, livery_tls:info({error, no_peercert})),
    ?assertEqual(#{verified => false}, livery_tls:info({error, closed})).

undecodable_certificate_keeps_der_test() ->
    ?assertEqual(
        #{verified => true, cert => <<"not a certificate">>},
        livery_tls:info({ok, <<"not a certificate">>})
    ).

subject_and_san_test() ->
    #{cert := Der} = public_key:pkix_test_root_cert("alice", []),
    #{verified := true, cert := Der, subject := Subject, san := San} =
        livery_tls:info({ok, Der}),
    ?assert(lists:member({<<"CN">>, <<"alice">>}, Subject)),
    ?assertEqual([], San).

%%====================================================================
%% check_listen_opts/1: raw TLS options cannot undo verify_peer
%%====================================================================

mtls(Raw) ->
    maps:merge(
        #{verify => verify_peer, cacerts => [<<"ca">>], stack => [], handler => fun(_) -> ok end},
        Raw
    ).

conflicting_ssl_opts_test_() ->
    [
        ?_assertEqual(
            {error, {conflicting_tls_opts, [Key]}},
            livery_tls:check_listen_opts(mtls(#{ssl_opts => [{Key, Value}]}))
        )
     || {Key, Value} <- [
            {verify, verify_none},
            {fail_if_no_peer_cert, false},
            {cacerts, []},
            {cacertfile, "other.pem"},
            {partial_chain, fun(_) -> unknown_ca end},
            {verify_fun, {fun(_, _, S) -> {valid, S} end, []}}
        ]
    ].

conflicting_quic_opts_test() ->
    ?assertEqual(
        {error, {conflicting_tls_opts, [cacerts, require_client_cert]}},
        livery_tls:check_listen_opts(
            mtls(#{quic_opts => #{require_client_cert => false, cacerts => []}})
        )
    ).

narrowing_options_allowed_test() ->
    ?assertEqual(
        ok, livery_tls:check_listen_opts(mtls(#{ssl_opts => [{crl_check, true}, {crl_cache, x}]}))
    ).

raw_override_kept_without_verify_peer_test() ->
    ?assertEqual(ok, livery_tls:check_listen_opts(#{ssl_opts => [{verify, verify_none}]})).

%% Every listener refuses before it binds or reads a certificate.
listeners_refuse_test_() ->
    Bad = mtls(#{ssl_opts => [{verify, verify_none}], transport => ssl, port => 0}),
    BadQuic = mtls(#{quic_opts => #{require_client_cert => false}, port => 0}),
    Expected = {error, {conflicting_tls_opts, [verify]}},
    [
        {"h1", ?_assertEqual(Expected, livery_h1:start(Bad))},
        {"h2", ?_assertEqual(Expected, livery_h2:start(Bad))},
        {"h1h2", ?_assertEqual(Expected, livery_h1h2:start(Bad#{alpn => [h2, http1]}))},
        {"h3",
            ?_assertEqual(
                {error, {conflicting_tls_opts, [require_client_cert]}},
                livery_h3:start(BadQuic#{name => livery_tls_refused})
            )}
    ].
