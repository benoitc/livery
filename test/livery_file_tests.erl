-module(livery_file_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Helpers
%%====================================================================

with_file(Content, Fun) ->
    Path = filename:join(
        temp_dir(),
        "livery_file_test_" ++
        integer_to_list(erlang:unique_integer([positive])) ++ ".bin"),
    ok = file:write_file(Path, Content),
    try Fun(Path) after file:delete(Path) end.

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir   -> Dir
    end.

run(Handler) ->
    livery_test_adapter:run([], Handler, #{}).

%%====================================================================
%% Whole-file emission
%%====================================================================

whole_file_test() ->
    Body = <<"hello world">>,
    with_file(Body, fun(Path) ->
        Cap = run(fun(_R) -> livery_resp:file(200, Path) end),
        ?assertEqual(200, livery_test_adapter:status(Cap)),
        ?assertEqual(Body, livery_test_adapter:body(Cap)),
        ?assertEqual(integer_to_binary(byte_size(Body)),
                     livery_test_adapter:header(<<"content-length">>, Cap)),
        ?assert(livery_test_adapter:end_stream(Cap))
    end).

empty_file_test() ->
    with_file(<<>>, fun(Path) ->
        Cap = run(fun(_R) -> livery_resp:file(200, Path) end),
        ?assertEqual(200, livery_test_adapter:status(Cap)),
        ?assertEqual(<<>>, livery_test_adapter:body(Cap)),
        ?assertEqual(<<"0">>,
                     livery_test_adapter:header(<<"content-length">>, Cap)),
        ?assert(livery_test_adapter:end_stream(Cap))
    end).

multi_chunk_file_test() ->
    %% Larger than one 64 KiB read, so emission spans several chunks.
    Body = binary:copy(<<"x">>, 200000),
    with_file(Body, fun(Path) ->
        Cap = run(fun(_R) -> livery_resp:file(200, Path) end),
        ?assertEqual(Body, livery_test_adapter:body(Cap)),
        ?assertEqual(integer_to_binary(byte_size(Body)),
                     livery_test_adapter:header(<<"content-length">>, Cap)),
        ?assert(length(livery_test_adapter:body_chunks(Cap)) >= 4)
    end).

content_type_passthrough_test() ->
    Body = <<"png-bytes">>,
    with_file(Body, fun(Path) ->
        Handler = fun(_R) ->
            R = livery_resp:file(200, Path),
            livery_resp:with_header(<<"content-type">>, <<"image/png">>, R)
        end,
        Cap = run(Handler),
        ?assertEqual(<<"image/png">>,
                     livery_test_adapter:header(<<"content-type">>, Cap)),
        ?assertEqual(integer_to_binary(byte_size(Body)),
                     livery_test_adapter:header(<<"content-length">>, Cap))
    end).

%%====================================================================
%% Byte ranges
%%====================================================================

range_offset_length_test() ->
    with_file(<<"0123456789">>, fun(Path) ->
        Cap = run(fun(_R) -> livery_resp:file(206, Path, {2, 3}) end),
        ?assertEqual(206, livery_test_adapter:status(Cap)),
        ?assertEqual(<<"234">>, livery_test_adapter:body(Cap)),
        ?assertEqual(<<"3">>,
                     livery_test_adapter:header(<<"content-length">>, Cap)),
        ?assertEqual(<<"bytes 2-4/10">>,
                     livery_test_adapter:header(<<"content-range">>, Cap))
    end).

range_to_eof_test() ->
    with_file(<<"0123456789">>, fun(Path) ->
        Cap = run(fun(_R) -> livery_resp:file(206, Path, {7, eof}) end),
        ?assertEqual(<<"789">>, livery_test_adapter:body(Cap)),
        ?assertEqual(<<"bytes 7-9/10">>,
                     livery_test_adapter:header(<<"content-range">>, Cap))
    end).

range_clamped_to_size_test() ->
    with_file(<<"0123456789">>, fun(Path) ->
        Cap = run(fun(_R) -> livery_resp:file(206, Path, {8, 100}) end),
        ?assertEqual(<<"89">>, livery_test_adapter:body(Cap)),
        ?assertEqual(<<"2">>,
                     livery_test_adapter:header(<<"content-length">>, Cap)),
        ?assertEqual(<<"bytes 8-9/10">>,
                     livery_test_adapter:header(<<"content-range">>, Cap))
    end).

%%====================================================================
%% Error cases
%%====================================================================

missing_file_test() ->
    Path = filename:join(temp_dir(), "livery_no_such_file_xyz.bin"),
    Cap = run(fun(_R) -> livery_resp:file(200, Path) end),
    ?assertEqual(404, livery_test_adapter:status(Cap)).

unsatisfiable_range_test() ->
    with_file(<<"0123456789">>, fun(Path) ->
        Cap = run(fun(_R) -> livery_resp:file(206, Path, {50, 1}) end),
        ?assertEqual(416, livery_test_adapter:status(Cap))
    end).
