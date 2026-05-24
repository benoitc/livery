-module(livery_compress_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

-define(JSON, <<"{\"hello\":\"world\",\"n\":12345,\"list\":[1,2,3,4,5]}">>).

%%====================================================================
%% Full-body negotiation
%%====================================================================

gzip_full_roundtrip_test() ->
    Cap = run_full(#{min_size => 0}, ?JSON, [{<<"accept-encoding">>, <<"gzip">>}]),
    ?assertEqual(<<"gzip">>, h(<<"content-encoding">>, Cap)),
    ?assert(has_vary(<<"accept-encoding">>, Cap)),
    Body = livery_test_adapter:body(Cap),
    ?assertEqual(integer_to_binary(byte_size(Body)), h(<<"content-length">>, Cap)),
    ?assertEqual(?JSON, zlib:gunzip(Body)).

deflate_full_roundtrip_test() ->
    Cap = run_full(#{min_size => 0}, ?JSON, [{<<"accept-encoding">>, <<"deflate">>}]),
    ?assertEqual(<<"deflate">>, h(<<"content-encoding">>, Cap)),
    ?assertEqual(?JSON, zlib:uncompress(livery_test_adapter:body(Cap))).

server_preference_wins_test() ->
    %% Client lists deflate first, but server order is [gzip, deflate].
    Cap = run_full(
        #{min_size => 0}, ?JSON, [{<<"accept-encoding">>, <<"deflate, gzip">>}]
    ),
    ?assertEqual(<<"gzip">>, h(<<"content-encoding">>, Cap)).

no_accept_encoding_passes_through_with_vary_test() ->
    Cap = run_full(#{min_size => 0}, ?JSON, []),
    ?assertEqual(undefined, h(<<"content-encoding">>, Cap)),
    ?assert(has_vary(<<"accept-encoding">>, Cap)),
    ?assertEqual(?JSON, livery_test_adapter:body(Cap)).

q_zero_rejects_gzip_test() ->
    Cap = run_full(
        #{min_size => 0}, ?JSON, [{<<"accept-encoding">>, <<"gzip;q=0">>}]
    ),
    ?assertEqual(undefined, h(<<"content-encoding">>, Cap)),
    ?assert(has_vary(<<"accept-encoding">>, Cap)).

wildcard_accept_encoding_test() ->
    Cap = run_full(#{min_size => 0}, ?JSON, [{<<"accept-encoding">>, <<"*">>}]),
    ?assertEqual(<<"gzip">>, h(<<"content-encoding">>, Cap)).

empty_codec_list_sends_identity_with_vary_test() ->
    Cap = run_full(
        #{min_size => 0, codecs => []},
        ?JSON,
        [{<<"accept-encoding">>, <<"gzip">>}]
    ),
    ?assertEqual(undefined, h(<<"content-encoding">>, Cap)),
    ?assert(has_vary(<<"accept-encoding">>, Cap)),
    ?assertEqual(?JSON, livery_test_adapter:body(Cap)).

%%====================================================================
%% Eligibility
%%====================================================================

already_encoded_passes_through_test() ->
    Handler = fun(_R) ->
        livery_resp:with_header(
            <<"content-encoding">>, <<"gzip">>, livery_resp:json(200, ?JSON)
        )
    end,
    Cap = livery_test_adapter:run(
        [{livery_compress, #{min_size => 0}}],
        Handler,
        #{headers => [{<<"accept-encoding">>, <<"gzip">>}]}
    ),
    %% unchanged: still the original (already-tagged) body, no Vary added
    ?assertEqual(?JSON, livery_test_adapter:body(Cap)),
    ?assertEqual([], vary_tokens(Cap)).

below_min_size_passes_through_test() ->
    Small = <<"hi">>,
    Cap = run_full(#{}, Small, [{<<"accept-encoding">>, <<"gzip">>}]),
    ?assertEqual(undefined, h(<<"content-encoding">>, Cap)),
    ?assertEqual([], vary_tokens(Cap)),
    ?assertEqual(Small, livery_test_adapter:body(Cap)).

non_compressible_type_passes_through_test() ->
    Handler = fun(_R) ->
        livery_resp:new(
            200,
            [{<<"content-type">>, <<"image/png">>}],
            {full, binary:copy(<<"x">>, 2000)}
        )
    end,
    Cap = livery_test_adapter:run(
        [{livery_compress, #{min_size => 0}}],
        Handler,
        #{headers => [{<<"accept-encoding">>, <<"gzip">>}]}
    ),
    ?assertEqual(undefined, h(<<"content-encoding">>, Cap)),
    ?assertEqual([], vary_tokens(Cap)).

content_type_with_params_is_compressible_test() ->
    Handler = fun(_R) ->
        livery_resp:new(
            200,
            [{<<"content-type">>, <<"Application/JSON; charset=utf-8">>}],
            {full, ?JSON}
        )
    end,
    Cap = livery_test_adapter:run(
        [{livery_compress, #{min_size => 0}}],
        Handler,
        #{headers => [{<<"accept-encoding">>, <<"gzip">>}]}
    ),
    ?assertEqual(<<"gzip">>, h(<<"content-encoding">>, Cap)),
    ?assertEqual(?JSON, zlib:gunzip(livery_test_adapter:body(Cap))).

sse_passes_through_test() ->
    Producer = fun(Emit) ->
        Emit(#{data => <<"1">>}),
        ok
    end,
    Cap = livery_test_adapter:run(
        [{livery_compress, #{min_size => 0}}],
        fun(_R) -> livery_resp:sse(200, Producer) end,
        #{headers => [{<<"accept-encoding">>, <<"gzip">>}]}
    ),
    ?assertEqual(undefined, h(<<"content-encoding">>, Cap)),
    ?assertEqual([], vary_tokens(Cap)).

empty_passes_through_test() ->
    Cap = livery_test_adapter:run(
        [{livery_compress, #{min_size => 0}}],
        fun(_R) -> livery_resp:empty(204) end,
        #{headers => [{<<"accept-encoding">>, <<"gzip">>}]}
    ),
    ?assertEqual(204, livery_test_adapter:status(Cap)),
    ?assertEqual(undefined, h(<<"content-encoding">>, Cap)),
    ?assertEqual([], vary_tokens(Cap)).

%%====================================================================
%% Chunked streaming
%%====================================================================

chunked_roundtrip_test() ->
    Producer = fun(Emit) ->
        Emit(<<"chunk-one-">>),
        Emit(<<"chunk-two-">>),
        Emit(<<"chunk-three">>),
        ok
    end,
    Handler = fun(_R) ->
        livery_resp:stream(
            200, [{<<"content-type">>, <<"application/json">>}], Producer
        )
    end,
    Cap = livery_test_adapter:run(
        [{livery_compress, #{}}],
        Handler,
        #{headers => [{<<"accept-encoding">>, <<"gzip">>}]}
    ),
    ?assertEqual(<<"gzip">>, h(<<"content-encoding">>, Cap)),
    ?assertEqual(undefined, h(<<"content-length">>, Cap)),
    ?assert(has_vary(<<"accept-encoding">>, Cap)),
    ?assertEqual(
        <<"chunk-one-chunk-two-chunk-three">>,
        zlib:gunzip(livery_test_adapter:body(Cap))
    ).

%%====================================================================
%% Trailers
%%====================================================================

full_with_trailers_drops_content_length_test() ->
    Handler = fun(_R) ->
        Resp = livery_resp:json(200, ?JSON),
        livery_resp:with_trailers([{<<"x-checksum">>, <<"abc">>}], Resp)
    end,
    Cap = livery_test_adapter:run(
        [{livery_compress, #{min_size => 0}}],
        Handler,
        #{headers => [{<<"accept-encoding">>, <<"gzip">>}]}
    ),
    ?assertEqual(<<"gzip">>, h(<<"content-encoding">>, Cap)),
    ?assertEqual(undefined, h(<<"content-length">>, Cap)),
    ?assertEqual([{<<"x-checksum">>, <<"abc">>}], livery_test_adapter:trailers(Cap)),
    ?assertEqual(?JSON, zlib:gunzip(livery_test_adapter:body(Cap))).

%%====================================================================
%% Registry
%%====================================================================

codec_registry_default_test() ->
    ?assertEqual(
        [livery_codec_gzip, livery_codec_deflate], livery_codec:registered()
    ).

codec_registry_append_test() ->
    try
        ok = livery_codec:register(fake_codec_xyz),
        R = livery_codec:registered(),
        ?assertEqual(
            [livery_codec_gzip, livery_codec_deflate, fake_codec_xyz], R
        ),
        %% idempotent
        ok = livery_codec:register(fake_codec_xyz),
        ?assertEqual(R, livery_codec:registered()),
        %% built-ins cannot be displaced
        ok = livery_codec:register(livery_codec_gzip),
        ?assertEqual(R, livery_codec:registered())
    after
        persistent_term:erase({livery_codec, extras})
    end.

%%====================================================================
%% Helpers
%%====================================================================

run_full(Cfg, Body, ReqHeaders) ->
    Handler = fun(_R) -> livery_resp:json(200, Body) end,
    livery_test_adapter:run(
        [{livery_compress, Cfg}], Handler, #{headers => ReqHeaders}
    ).

h(Name, Cap) ->
    livery_test_adapter:header(Name, Cap).

vary_tokens(Cap) ->
    Values = [V || {<<"vary">>, V} <- livery_test_adapter:headers(Cap)],
    lists:flatmap(
        fun(V) ->
            [normalize_token(T) || T <- binary:split(V, <<",">>, [global])]
        end,
        Values
    ).

has_vary(Token, Cap) ->
    lists:member(normalize_token(Token), vary_tokens(Cap)).

normalize_token(Token) ->
    iolist_to_binary(string:trim(string:lowercase(Token))).
