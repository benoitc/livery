%% @doc TOTP (RFC 6238) and its base32 encoding (RFC 4648).
-module(livery_auth_totp_tests).

-include_lib("eunit/include/eunit.hrl").

%% RFC 6238 Appendix B: one seed per algorithm, 8 digits, 30 s steps.
seed(sha1) -> <<"12345678901234567890">>;
seed(sha256) -> <<"12345678901234567890123456789012">>;
seed(sha512) -> <<(binary:copy(<<"1234567890">>, 6))/binary, "1234">>.

rfc6238_vectors_test_() ->
    Vectors = [
        {59, <<"94287082">>, <<"46119246">>, <<"90693936">>},
        {1111111109, <<"07081804">>, <<"68084774">>, <<"25091201">>},
        {1111111111, <<"14050471">>, <<"67062674">>, <<"99943326">>},
        {1234567890, <<"89005924">>, <<"91819424">>, <<"93441116">>},
        {2000000000, <<"69279037">>, <<"90698825">>, <<"38618901">>},
        {20000000000, <<"65353130">>, <<"77737706">>, <<"47863826">>}
    ],
    [
        ?_assertEqual(
            Expected, livery_auth_totp:code(seed(Alg), #{algorithm => Alg, digits => 8, now => T})
        )
     || {T, S1, S256, S512} <- Vectors,
        {Alg, Expected} <- [{sha1, S1}, {sha256, S256}, {sha512, S512}]
    ].

%%====================================================================
%% verify/3
%%====================================================================

-define(T, 1700000000).

code_at(Offset) -> livery_auth_totp:code(seed(sha1), #{now => ?T + Offset}).

verify(Code, Opts) -> livery_auth_totp:verify(Code, seed(sha1), maps:merge(#{now => ?T}, Opts)).

step() -> ?T div 30.

window_test_() ->
    [
        {"current step", ?_assertEqual({ok, step()}, verify(code_at(0), #{}))},
        {"previous step", ?_assertEqual({ok, step() - 1}, verify(code_at(-30), #{}))},
        {"next step", ?_assertEqual({ok, step() + 1}, verify(code_at(30), #{}))},
        {"two steps back", ?_assertEqual(error, verify(code_at(-60), #{}))},
        {"two steps ahead", ?_assertEqual(error, verify(code_at(60), #{}))},
        {"wider window", ?_assertEqual({ok, step() - 2}, verify(code_at(-60), #{window => 2}))},
        {"no window", ?_assertEqual(error, verify(code_at(-30), #{window => 0}))}
    ].

%% A code is good once: the step it matched becomes `last_step'.
replay_test() ->
    Code = code_at(0),
    {ok, Step} = verify(Code, #{}),
    ?assertEqual(error, verify(Code, #{last_step => Step})),
    ?assertEqual(error, verify(code_at(-30), #{last_step => Step})),
    ?assertEqual({ok, Step + 1}, verify(code_at(30), #{last_step => Step})).

bad_input_test_() ->
    [
        ?_assertEqual(error, verify(Bad, #{}))
     || Bad <- [<<>>, <<"12345">>, <<"1234567">>, <<"12a456">>, <<" 123456">>, not_a_binary]
    ].

eight_digits_test() ->
    Code = livery_auth_totp:code(seed(sha1), #{now => ?T, digits => 8}),
    ?assertEqual(8, byte_size(Code)),
    ?assertMatch({ok, _}, verify(Code, #{digits => 8})).

%%====================================================================
%% Secrets, base32, URI
%%====================================================================

secret_test() ->
    ?assertEqual(20, byte_size(livery_auth_totp:secret())),
    ?assertNotEqual(livery_auth_totp:secret(), livery_auth_totp:secret()).

%% RFC 4648 section 10, without padding.
rfc4648_vectors_test_() ->
    Vectors = [
        {<<>>, <<>>},
        {<<"f">>, <<"MY">>},
        {<<"fo">>, <<"MZXQ">>},
        {<<"foo">>, <<"MZXW6">>},
        {<<"foob">>, <<"MZXW6YQ">>},
        {<<"fooba">>, <<"MZXW6YTB">>},
        {<<"foobar">>, <<"MZXW6YTBOI">>}
    ],
    lists:append([
        [
            ?_assertEqual(Enc, livery_auth_totp:encode(Raw)),
            ?_assertEqual({ok, Raw}, livery_auth_totp:decode(Enc))
        ]
     || {Raw, Enc} <- Vectors
    ]).

decode_is_lenient_and_strict_test() ->
    ?assertEqual({ok, <<"foobar">>}, livery_auth_totp:decode(<<"mzxw 6ytb oi======">>)),
    ?assertEqual(error, livery_auth_totp:decode(<<"MZXW1">>)).

round_trip_test() ->
    Secret = livery_auth_totp:secret(),
    ?assertEqual({ok, Secret}, livery_auth_totp:decode(livery_auth_totp:encode(Secret))).

uri_test() ->
    Uri = livery_auth_totp:uri(<<"12345678901234567890">>, #{
        issuer => <<"Acme Co">>, account => <<"alice@example.org">>
    }),
    ?assertEqual(
        <<"otpauth://totp/Acme%20Co%3Aalice%40example.org?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Acme+Co">>,
        Uri
    ).

uri_with_options_test() ->
    Uri = livery_auth_totp:uri(<<"k">>, #{
        issuer => <<"A">>, account => <<"b">>, algorithm => sha256, digits => 8, period => 60
    }),
    #{query := Q} = uri_string:parse(Uri),
    ?assertMatch(
        [_, _, {<<"algorithm">>, <<"SHA256">>}, {<<"digits">>, <<"8">>}, {<<"period">>, <<"60">>}],
        uri_string:dissect_query(Q)
    ).
