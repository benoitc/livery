%% @doc livery_cbor against the RFC 8949 Appendix A examples it supports,
%% and the inputs it must refuse.
-module(livery_cbor_tests).

-include_lib("eunit/include/eunit.hrl").

hex(H) -> binary:decode_hex(H).

decodes(Hex) ->
    {ok, V, <<>>} = livery_cbor:decode(hex(Hex)),
    V.

rfc8949_vectors_test_() ->
    Vectors = [
        {<<"00">>, 0},
        {<<"01">>, 1},
        {<<"0a">>, 10},
        {<<"17">>, 23},
        {<<"1818">>, 24},
        {<<"1819">>, 25},
        {<<"1864">>, 100},
        {<<"1903e8">>, 1000},
        {<<"1a000f4240">>, 1000000},
        {<<"1b000000e8d4a51000">>, 1000000000000},
        {<<"1bffffffffffffffff">>, 18446744073709551615},
        {<<"3bffffffffffffffff">>, -18446744073709551616},
        {<<"20">>, -1},
        {<<"29">>, -10},
        {<<"3863">>, -100},
        {<<"3903e7">>, -1000},
        {<<"f4">>, false},
        {<<"f5">>, true},
        {<<"f6">>, null},
        {<<"40">>, {bytes, <<>>}},
        {<<"4401020304">>, {bytes, <<1, 2, 3, 4>>}},
        {<<"60">>, <<>>},
        {<<"6161">>, <<"a">>},
        {<<"6449455446">>, <<"IETF">>},
        {<<"62225c">>, <<"\"\\">>},
        {<<"62c3bc">>, <<"ü"/utf8>>},
        {<<"63e6b0b4">>, <<"水"/utf8>>},
        {<<"64f0908591">>, <<16#10151/utf8>>},
        {<<"80">>, []},
        {<<"83010203">>, [1, 2, 3]},
        {<<"8301820203820405">>, [1, [2, 3], [4, 5]]},
        {<<"98190102030405060708090a0b0c0d0e0f101112131415161718181819">>, lists:seq(1, 25)},
        {<<"a0">>, #{}},
        {<<"a201020304">>, #{1 => 2, 3 => 4}},
        {<<"a26161016162820203">>, #{<<"a">> => 1, <<"b">> => [2, 3]}},
        {<<"826161a161626163">>, [<<"a">>, #{<<"b">> => <<"c">>}]},
        {<<"a56161614161626142616361436164614461656145">>, #{
            <<"a">> => <<"A">>,
            <<"b">> => <<"B">>,
            <<"c">> => <<"C">>,
            <<"d">> => <<"D">>,
            <<"e">> => <<"E">>
        }}
    ],
    [?_assertEqual(Expected, decodes(Hex)) || {Hex, Expected} <- Vectors].

rest_is_returned_test() ->
    ?assertEqual({ok, 1, <<2, 3>>}, livery_cbor:decode(<<1, 2, 3>>)).

refusals_test_() ->
    Cases = [
        {"indefinite byte string", <<"5f42010243030405ff">>, indefinite_length},
        {"indefinite array", <<"9f018202039f0405ffff">>, indefinite_length},
        {"indefinite map", <<"bf61610161629f0203ffff">>, indefinite_length},
        {"tag", <<"c11a514b67b0">>, tag},
        {"half float", <<"f93c00">>, unsupported_simple_value},
        {"double", <<"fb3ff199999999999a">>, unsupported_simple_value},
        {"undefined", <<"f7">>, unsupported_simple_value},
        {"reserved additional info", <<"1c">>, reserved},
        {"truncated integer", <<"19 01"/utf8>>, truncated},
        {"string past the end", <<"4501020304">>, truncated},
        {"array past the end", <<"830102">>, truncated},
        {"duplicate key", <<"a201020103">>, duplicate_key},
        {"invalid utf-8", <<"62c328">>, invalid_utf8},
        {"empty input", <<>>, truncated}
    ],
    [
        {Name, ?_assertEqual({error, Reason}, livery_cbor:decode(input(Hex)))}
     || {Name, Hex, Reason} <- Cases
    ].

input(<<"19 01">>) -> <<16#19, 16#01>>;
input(Hex) -> hex(Hex).

too_deep_test() ->
    Deep = <<(binary:copy(<<16#81>>, 17))/binary, 0>>,
    ?assertEqual({error, too_deep}, livery_cbor:decode(Deep)),
    Ok = <<(binary:copy(<<16#81>>, 16))/binary, 0>>,
    ?assertMatch({ok, _, <<>>}, livery_cbor:decode(Ok)).
