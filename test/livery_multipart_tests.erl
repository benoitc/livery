-module(livery_multipart_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Buffered parsing
%%====================================================================

single_text_field_test() ->
    B = <<"X">>,
    Bin = build(B, [{[cd(<<"greeting">>)], <<"hello">>}]),
    {ok, [Part]} = livery_multipart:read_all(buffered_req(B, Bin)),
    ?assertEqual(<<"greeting">>, maps:get(name, Part)),
    ?assertEqual(undefined, maps:get(filename, Part)),
    ?assertEqual(<<"hello">>, maps:get(body, Part)).

file_part_test() ->
    B = <<"BOUNDARY">>,
    CD = <<"form-data; name=\"file\"; filename=\"a.txt\"">>,
    Hs = [{<<"Content-Disposition">>, CD}, {<<"Content-Type">>, <<"text/plain">>}],
    Bin = build(B, [{Hs, <<"FILEDATA">>}]),
    {ok, [P]} = livery_multipart:read_all(buffered_req(B, Bin)),
    ?assertEqual(<<"file">>, maps:get(name, P)),
    ?assertEqual(<<"a.txt">>, maps:get(filename, P)),
    ?assertEqual(<<"text/plain">>, maps:get(content_type, P)),
    ?assertEqual(<<"FILEDATA">>, maps:get(body, P)).

case_insensitive_content_type_test() ->
    B = <<"b">>,
    Bin = build(B, [{[cd(<<"x">>)], <<"v">>}]),
    Req = livery_req:new(#{
        headers => [{<<"content-type">>, <<"Multipart/Form-Data; boundary=", B/binary>>}],
        body => {buffered, Bin}
    }),
    {ok, [P]} = livery_multipart:read_all(Req),
    ?assertEqual(<<"v">>, maps:get(body, P)).

rfc_fixture_test() ->
    B = <<"----WebKitFormBoundaryABC123">>,
    FileHs = [
        {<<"Content-Disposition">>, <<"form-data; name=\"upload\"; filename=\"hello.txt\"">>},
        {<<"Content-Type">>, <<"text/plain">>}
    ],
    Inner = build(B, [
        {[cd(<<"field1">>)], <<"value1">>},
        {[cd(<<"field2">>)], <<"value2">>},
        {FileHs, <<"file contents here">>}
    ]),
    WithPad = <<"preamble to ignore\r\n", Inner/binary, "epilogue ignored">>,
    {ok, Parts} = livery_multipart:read_all(buffered_req(B, WithPad)),
    ?assertEqual(3, length(Parts)),
    [P1, P2, P3] = Parts,
    ?assertEqual({<<"field1">>, <<"value1">>}, {maps:get(name, P1), maps:get(body, P1)}),
    ?assertEqual({<<"field2">>, <<"value2">>}, {maps:get(name, P2), maps:get(body, P2)}),
    ?assertEqual(<<"hello.txt">>, maps:get(filename, P3)),
    ?assertEqual(<<"text/plain">>, maps:get(content_type, P3)),
    ?assertEqual(<<"file contents here">>, maps:get(body, P3)).

%%====================================================================
%% Streaming parsing
%%====================================================================

multiple_parts_stream_test() ->
    B = <<"B">>,
    Bin = build(B, [{[cd(<<"a">>)], <<"one">>}, {[cd(<<"b">>)], <<"two">>}]),
    {ok, MP0} = livery_multipart:new(stream_req(B, [Bin])),
    {part, P1, MP1} = livery_multipart:next_part(MP0, 1000),
    ?assertEqual(<<"a">>, maps:get(name, P1)),
    {ok, Body1, MP2} = read_full(MP1),
    ?assertEqual(<<"one">>, Body1),
    {part, P2, MP3} = livery_multipart:next_part(MP2, 1000),
    ?assertEqual(<<"b">>, maps:get(name, P2)),
    {ok, Body2, MP4} = read_full(MP3),
    ?assertEqual(<<"two">>, Body2),
    ?assertMatch({done, _}, livery_multipart:next_part(MP4, 1000)).

split_boundary_across_chunks_test() ->
    B = <<"sep">>,
    Body = <<"hello world">>,
    Bin = build(B, [{[cd(<<"a">>)], Body}]),
    Delim = <<"\r\n--", B/binary>>,
    {Pos, _} = binary:match(Bin, Delim),
    %% split in the middle of the part-terminating delimiter
    SplitAt = Pos + 3,
    <<C1:SplitAt/binary, C2/binary>> = Bin,
    {ok, [P]} = livery_multipart:read_all(stream_req(B, [C1, C2])),
    ?assertEqual(Body, maps:get(body, P)).

buffered_matches_stream_test() ->
    B = <<"b">>,
    Bin = build(B, [{[cd(<<"x">>)], <<"some longer body value">>}]),
    {ok, Buffered} = livery_multipart:read_all(buffered_req(B, Bin)),
    {ok, Streamed} = livery_multipart:read_all(stream_req(B, chunks(Bin, 3))),
    ?assertEqual(Buffered, Streamed).

next_part_skips_unread_body_test() ->
    B = <<"b">>,
    Bin = build(B, [{[cd(<<"a">>)], <<"AAAA">>}, {[cd(<<"b">>)], <<"BBBB">>}]),
    {ok, MP0} = livery_multipart:new(buffered_req(B, Bin)),
    {part, _P1, MP1} = livery_multipart:next_part(MP0, 1000),
    %% skip part 1's body entirely
    {part, P2, MP2} = livery_multipart:next_part(MP1, 1000),
    ?assertEqual(<<"b">>, maps:get(name, P2)),
    ?assertEqual({ok, <<"BBBB">>}, drop_reader(read_full(MP2))).

%%====================================================================
%% Empty / malformed
%%====================================================================

empty_body_yields_done_test() ->
    Req = livery_req:new(#{
        headers => [{<<"content-type">>, <<"multipart/form-data; boundary=b">>}],
        body => empty
    }),
    {ok, MP0} = livery_multipart:new(Req),
    ?assertMatch({done, _}, livery_multipart:next_part(MP0, 1000)).

garbage_without_boundary_is_malformed_test() ->
    B = <<"b">>,
    {ok, MP0} = livery_multipart:new(buffered_req(B, <<"no boundary here at all">>)),
    ?assertMatch({error, malformed, _}, livery_multipart:next_part(MP0, 1000)).

malformed_header_test() ->
    B = <<"b">>,
    Bin = <<"--b\r\nthisisnotaheader\r\n\r\nbody\r\n--b--\r\n">>,
    {ok, MP0} = livery_multipart:new(buffered_req(B, Bin)),
    ?assertMatch({error, malformed, _}, livery_multipart:next_part(MP0, 1000)).

not_multipart_test() ->
    Req = livery_req:new(#{
        headers => [{<<"content-type">>, <<"application/json">>}],
        body => {buffered, <<"{}">>}
    }),
    ?assertEqual({error, not_multipart}, livery_multipart:new(Req)).

missing_content_type_test() ->
    Req = livery_req:new(#{body => {buffered, <<>>}}),
    ?assertEqual({error, not_multipart}, livery_multipart:new(Req)).

no_boundary_test() ->
    Req = livery_req:new(#{
        headers => [{<<"content-type">>, <<"multipart/form-data">>}],
        body => {buffered, <<>>}
    }),
    ?assertEqual({error, no_boundary}, livery_multipart:new(Req)).

%%====================================================================
%% Limits / security
%%====================================================================

max_parts_test() ->
    B = <<"b">>,
    Bin = build(B, [
        {[cd(<<"a">>)], <<"1">>},
        {[cd(<<"b">>)], <<"2">>},
        {[cd(<<"c">>)], <<"3">>}
    ]),
    ?assertEqual(
        {error, {limit, max_parts}},
        livery_multipart:read_all(buffered_req(B, Bin), #{max_parts => 2})
    ).

max_part_size_test() ->
    B = <<"b">>,
    Bin = build(B, [{[cd(<<"a">>)], <<"abcdefghij">>}]),
    ?assertEqual(
        {error, {limit, max_part_size}},
        livery_multipart:read_all(buffered_req(B, Bin), #{max_part_size => 4})
    ).

max_header_bytes_test() ->
    B = <<"b">>,
    Big = binary:copy(<<"x">>, 200),
    Bin = build(B, [{[cd(<<"a">>), {<<"X-Big">>, Big}], <<"v">>}]),
    {ok, MP0} = livery_multipart:new(buffered_req(B, Bin), #{max_header_bytes => 50}),
    ?assertMatch({error, {limit, max_header_bytes}, _}, livery_multipart:next_part(MP0, 1000)).

max_header_count_test() ->
    B = <<"b">>,
    Extra = [{<<"X-N">>, integer_to_binary(N)} || N <- lists:seq(1, 10)],
    Bin = build(B, [{[cd(<<"a">>) | Extra], <<"v">>}]),
    {ok, MP0} = livery_multipart:new(buffered_req(B, Bin), #{max_header_count => 3}),
    ?assertMatch({error, {limit, max_header_count}, _}, livery_multipart:next_part(MP0, 1000)).

max_body_test() ->
    B = <<"b">>,
    Bin = build(B, [{[cd(<<"a">>)], binary:copy(<<"z">>, 100)}]),
    ?assertEqual(
        {error, {limit, max_body}},
        livery_multipart:read_all(buffered_req(B, Bin), #{max_body => 20})
    ).

traversal_filename_returned_verbatim_test() ->
    B = <<"b">>,
    CD = <<"form-data; name=\"f\"; filename=\"../../etc/passwd\"">>,
    Bin = build(B, [{[{<<"Content-Disposition">>, CD}], <<"x">>}]),
    {ok, [P]} = livery_multipart:read_all(buffered_req(B, Bin)),
    ?assertEqual(<<"../../etc/passwd">>, maps:get(filename, P)).

client_reset_mid_part_test() ->
    B = <<"b">>,
    Ref = make_ref(),
    Head = <<"--b\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\npartial body data">>,
    self() ! {livery_body, Ref, {data, Head}},
    self() ! {livery_body, Ref, {reset, closed}},
    Req = make_req(B, {stream, livery_body:new(Ref)}),
    {ok, MP0} = livery_multipart:new(Req),
    {part, _P, MP1} = livery_multipart:next_part(MP0, 1000),
    ?assertMatch({error, {client_reset, closed}, _}, read_until_end(MP1)).

%%====================================================================
%% Helpers
%%====================================================================

cd(Name) ->
    {<<"Content-Disposition">>, <<"form-data; name=\"", Name/binary, "\"">>}.

build(Boundary, Parts) ->
    Open = <<"--", Boundary/binary, "\r\n">>,
    Mid = <<"\r\n--", Boundary/binary, "\r\n">>,
    Close = <<"\r\n--", Boundary/binary, "--\r\n">>,
    Blocks = [part_block(Hs, Body) || {Hs, Body} <- Parts],
    iolist_to_binary([Open, lists:join(Mid, Blocks), Close]).

part_block(Hs, Body) ->
    HeaderLines = [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Hs],
    [HeaderLines, <<"\r\n">>, Body].

buffered_req(Boundary, Bin) ->
    make_req(Boundary, {buffered, Bin}).

stream_req(Boundary, Chunks) ->
    Ref = make_ref(),
    [self() ! {livery_body, Ref, {data, C}} || C <- Chunks],
    self() ! {livery_body, Ref, eof},
    make_req(Boundary, {stream, livery_body:new(Ref)}).

make_req(Boundary, Body) ->
    livery_req:new(#{
        headers => [
            {<<"content-type">>, <<"multipart/form-data; boundary=", Boundary/binary>>}
        ],
        body => Body
    }).

chunks(Bin, N) ->
    chunks(Bin, N, []).

chunks(<<>>, _N, Acc) ->
    lists:reverse(Acc);
chunks(Bin, N, Acc) when byte_size(Bin) =< N ->
    lists:reverse([Bin | Acc]);
chunks(Bin, N, Acc) ->
    <<Head:N/binary, Rest/binary>> = Bin,
    chunks(Rest, N, [Head | Acc]).

read_full(MP) ->
    read_full(MP, []).

read_full(MP, Acc) ->
    case livery_multipart:read_part(MP, 1000) of
        {ok, Chunk, MP1} -> read_full(MP1, [Chunk | Acc]);
        {done, MP1} -> {ok, iolist_to_binary(lists:reverse(Acc)), MP1};
        {error, R, MP1} -> {error, R, MP1}
    end.

read_until_end(MP) ->
    case livery_multipart:read_part(MP, 1000) of
        {ok, _Chunk, MP1} -> read_until_end(MP1);
        Other -> Other
    end.

drop_reader({ok, Body, _MP}) -> {ok, Body};
drop_reader(Other) -> Other.
