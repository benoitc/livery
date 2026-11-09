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
