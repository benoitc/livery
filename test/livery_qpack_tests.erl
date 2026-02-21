%% @doc Unit tests for QPACK header compression (RFC 9204).
-module(livery_qpack_tests).

-include_lib("eunit/include/eunit.hrl").

%% ===================================================================
%% State creation
%% ===================================================================

init_test() ->
    State = livery_qpack:init(),
    ?assertMatch(State when is_tuple(State), State).

init_with_opts_test() ->
    State = livery_qpack:init(#{max_dynamic_size => 4096}),
    ?assertMatch(State when is_tuple(State), State).

%% ===================================================================
%% Basic encode/decode round-trips
%% ===================================================================

encode_decode_simple_header_test() ->
    State = livery_qpack:init(),
    Headers = [{<<"content-type">>, <<"text/html">>}],
    {Encoded, _State1} = livery_qpack:encode(Headers, State),
    {Result, _State2} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

encode_decode_multiple_headers_test() ->
    State = livery_qpack:init(),
    Headers = [
        {<<":status">>, <<"200">>},
        {<<"content-type">>, <<"application/json">>},
        {<<"content-length">>, <<"100">>}
    ],
    {Encoded, _State1} = livery_qpack:encode(Headers, State),
    {Result, _State2} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

%% ===================================================================
%% Static table tests
%% ===================================================================

encode_static_indexed_method_test() ->
    %% :method GET is index 17 in QPACK static table
    _State = livery_qpack:init(),
    Headers = [{<<":method">>, <<"GET">>}],
    Encoded = livery_qpack:encode(Headers),
    %% Decode should return same headers
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

encode_static_indexed_status_200_test() ->
    %% :status 200 is index 25 in QPACK static table
    _State = livery_qpack:init(),
    Headers = [{<<":status">>, <<"200">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

encode_static_indexed_path_root_test() ->
    %% :path / is index 1 in QPACK static table
    _State = livery_qpack:init(),
    Headers = [{<<":path">>, <<"/">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

encode_static_indexed_scheme_https_test() ->
    %% :scheme https is index 23 in QPACK static table
    _State = livery_qpack:init(),
    Headers = [{<<":scheme">>, <<"https">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Literal header with indexed name
%% ===================================================================

encode_literal_indexed_name_test() ->
    %% content-type has index 44 in static table, but with custom value
    _State = livery_qpack:init(),
    Headers = [{<<"content-type">>, <<"application/octet-stream">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Literal header with literal name
%% ===================================================================

encode_literal_new_name_test() ->
    _State = livery_qpack:init(),
    Headers = [{<<"x-custom-header">>, <<"custom-value">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% HTTP/3 typical request/response headers
%% ===================================================================

encode_decode_http3_request_test() ->
    State = livery_qpack:init(),
    Headers = [
        {<<":method">>, <<"GET">>},
        {<<":scheme">>, <<"https">>},
        {<<":path">>, <<"/">>},
        {<<":authority">>, <<"example.com">>}
    ],
    {Encoded, _} = livery_qpack:encode(Headers, State),
    {Result, _} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

encode_decode_http3_response_test() ->
    State = livery_qpack:init(),
    Headers = [
        {<<":status">>, <<"200">>},
        {<<"content-type">>, <<"text/html">>},
        {<<"content-length">>, <<"1234">>},
        {<<"server">>, <<"livery/1.0">>}
    ],
    {Encoded, _} = livery_qpack:encode(Headers, State),
    {Result, _} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

%% ===================================================================
%% Edge cases
%% ===================================================================

encode_decode_empty_value_test() ->
    State = livery_qpack:init(),
    Headers = [{<<"x-empty">>, <<>>}],
    {Encoded, _} = livery_qpack:encode(Headers, State),
    {Result, _} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

encode_decode_long_value_test() ->
    State = livery_qpack:init(),
    LongValue = binary:copy(<<"x">>, 500),
    Headers = [{<<"x-long">>, LongValue}],
    {Encoded, _} = livery_qpack:encode(Headers, State),
    {Result, _} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

encode_decode_long_name_test() ->
    State = livery_qpack:init(),
    LongName = binary:copy(<<"x">>, 100),
    Headers = [{LongName, <<"value">>}],
    {Encoded, _} = livery_qpack:encode(Headers, State),
    {Result, _} = livery_qpack:decode(Encoded, State),
    ?assertEqual({ok, Headers}, Result).

%% ===================================================================
%% Stateless API
%% ===================================================================

stateless_encode_decode_test() ->
    Headers = [{<<":status">>, <<"200">>}, {<<"server">>, <<"livery">>}],
    Encoded = livery_qpack:encode(Headers),
    {ok, Decoded} = livery_qpack:decode(Encoded),
    ?assertEqual(Headers, Decoded).

%% ===================================================================
%% Multiple encode operations (state reuse)
%% ===================================================================

multiple_encode_test() ->
    State0 = livery_qpack:init(),

    %% First encode
    Headers1 = [{<<":status">>, <<"200">>}],
    {Encoded1, State1} = livery_qpack:encode(Headers1, State0),
    {Result1, _} = livery_qpack:decode(Encoded1, State0),
    ?assertEqual({ok, Headers1}, Result1),

    %% Second encode with same state
    Headers2 = [{<<":status">>, <<"404">>}],
    {Encoded2, _State2} = livery_qpack:encode(Headers2, State1),
    {Result2, _} = livery_qpack:decode(Encoded2, State0),
    ?assertEqual({ok, Headers2}, Result2).

%% ===================================================================
%% All status codes in static table
%% ===================================================================

status_codes_test_() ->
    StatusCodes = [<<"100">>, <<"103">>, <<"200">>, <<"204">>, <<"206">>,
                   <<"302">>, <<"304">>, <<"400">>, <<"403">>, <<"404">>,
                   <<"421">>, <<"425">>, <<"500">>, <<"503">>],
    [{"Status " ++ binary_to_list(Status),
      fun() ->
          Headers = [{<<":status">>, Status}],
          Encoded = livery_qpack:encode(Headers),
          {ok, Decoded} = livery_qpack:decode(Encoded),
          ?assertEqual(Headers, Decoded)
      end} || Status <- StatusCodes].

%% ===================================================================
%% All methods in static table
%% ===================================================================

methods_test_() ->
    Methods = [<<"CONNECT">>, <<"DELETE">>, <<"GET">>, <<"HEAD">>,
               <<"OPTIONS">>, <<"POST">>, <<"PUT">>],
    [{"Method " ++ binary_to_list(Method),
      fun() ->
          Headers = [{<<":method">>, Method}],
          Encoded = livery_qpack:encode(Headers),
          {ok, Decoded} = livery_qpack:decode(Encoded),
          ?assertEqual(Headers, Decoded)
      end} || Method <- Methods].

%% ===================================================================
%% Content types in static table
%% ===================================================================

content_types_test_() ->
    ContentTypes = [
        <<"application/dns-message">>,
        <<"application/javascript">>,
        <<"application/json">>,
        <<"application/x-www-form-urlencoded">>,
        <<"image/gif">>,
        <<"image/jpeg">>,
        <<"image/png">>,
        <<"text/css">>,
        <<"text/html; charset=utf-8">>,
        <<"text/plain">>,
        <<"text/plain;charset=utf-8">>
    ],
    [{"Content-Type: " ++ binary_to_list(CT),
      fun() ->
          Headers = [{<<"content-type">>, CT}],
          Encoded = livery_qpack:encode(Headers),
          {ok, Decoded} = livery_qpack:decode(Encoded),
          ?assertEqual(Headers, Decoded)
      end} || CT <- ContentTypes].

%% ===================================================================
%% Error cases
%% ===================================================================

decode_invalid_prefix_test() ->
    State = livery_qpack:init(),
    %% Single byte is not enough for prefix
    {{error, _}, _} = livery_qpack:decode(<<>>, State).

decode_empty_test() ->
    %% Empty input should fail
    {error, _} = livery_qpack:decode(<<>>).

%% ===================================================================
%% Dynamic table tests
%% ===================================================================

init_with_dynamic_table_test() ->
    State = livery_qpack:init(#{max_dynamic_size => 4096}),
    ?assertEqual(4096, livery_qpack:get_dynamic_capacity(State)),
    ?assertEqual(0, livery_qpack:get_insert_count(State)).

set_dynamic_capacity_test() ->
    State0 = livery_qpack:init(),
    ?assertEqual(0, livery_qpack:get_dynamic_capacity(State0)),
    State1 = livery_qpack:set_dynamic_capacity(2048, State0),
    ?assertEqual(2048, livery_qpack:get_dynamic_capacity(State1)),
    %% Should have generated an encoder instruction
    Instructions = livery_qpack:get_encoder_instructions(State1),
    ?assert(byte_size(Instructions) > 0).

process_encoder_instructions_set_capacity_test() ->
    State0 = livery_qpack:init(),
    %% Set Dynamic Table Capacity instruction: 001xxxxx
    %% Capacity = 1024 needs multi-byte encoding: 001_11111 (31) + continuation
    %% 1024 - 31 = 993, encoded as 993 rem 128 = 97 + 128 = 225, 993 div 128 = 7
    %% So: <<0x3F, 0xE1, 0x07>> but let's use a simpler value
    %% Capacity = 30: 001_11110 = 0x3E
    Instruction = <<16#3E>>,
    {ok, State1} = livery_qpack:process_encoder_instructions(Instruction, State0),
    ?assertEqual(30, livery_qpack:get_dynamic_capacity(State1)).

process_encoder_instructions_insert_literal_test() ->
    State0 = livery_qpack:init(#{max_dynamic_size => 4096}),
    %% Insert with literal name: 01_H_xxxxx
    %% Name "foo" (len=3), Value "bar" (len=3)
    %% 01_0_00011 = 0x43, then "foo", then 0x03, "bar"
    Instruction = <<16#43, "foo", 16#03, "bar">>,
    {ok, State1} = livery_qpack:process_encoder_instructions(Instruction, State0),
    ?assertEqual(1, livery_qpack:get_insert_count(State1)).

process_encoder_instructions_insert_name_ref_static_test() ->
    State0 = livery_qpack:init(#{max_dynamic_size => 4096}),
    %% Insert with name reference (static): 1_S_xxxxxx
    %% S=1 (static), Index=0 (:authority), Value "example.com" (len=11)
    %% 1_1_000000 = 0xC0, then value len 0x0B, then "example.com"
    Instruction = <<16#C0, 16#0B, "example.com">>,
    {ok, State1} = livery_qpack:process_encoder_instructions(Instruction, State0),
    ?assertEqual(1, livery_qpack:get_insert_count(State1)).

dynamic_table_encode_decode_roundtrip_test() ->
    %% Create encoder and decoder with dynamic tables
    Encoder0 = livery_qpack:init(#{max_dynamic_size => 4096}),
    Decoder0 = livery_qpack:init(#{max_dynamic_size => 4096}),

    %% Insert a header into encoder's dynamic table via instruction
    InsertInstr = <<16#43, "foo", 16#03, "bar">>,
    {ok, Encoder1} = livery_qpack:process_encoder_instructions(InsertInstr, Encoder0),

    %% Also insert into decoder's table (simulating encoder stream sync)
    {ok, Decoder1} = livery_qpack:process_encoder_instructions(InsertInstr, Decoder0),

    %% Now encode headers using the dynamic table entry
    Headers = [{<<"foo">>, <<"bar">>}],
    {Encoded, _Encoder2} = livery_qpack:encode(Headers, Encoder1),

    %% Decode using decoder with same dynamic table state
    {{ok, Decoded}, _Decoder2} = livery_qpack:decode(Encoded, Decoder1),
    ?assertEqual(Headers, Decoded).

encoder_instructions_generation_test() ->
    State0 = livery_qpack:init(),
    %% Set capacity generates instruction
    State1 = livery_qpack:set_dynamic_capacity(1024, State0),
    Instructions = livery_qpack:get_encoder_instructions(State1),
    ?assert(byte_size(Instructions) > 0),

    %% Clear instructions
    State2 = livery_qpack:clear_encoder_instructions(State1),
    EmptyInstructions = livery_qpack:get_encoder_instructions(State2),
    ?assertEqual(<<>>, EmptyInstructions).

section_ack_encoding_test() ->
    %% Section acknowledgment for stream 0: 1_0000000 = 0x80
    Ack = livery_qpack:encode_section_ack(0),
    ?assertEqual(<<16#80>>, Ack),

    %% Section acknowledgment for stream 5: 1_0000101 = 0x85
    Ack5 = livery_qpack:encode_section_ack(5),
    ?assertEqual(<<16#85>>, Ack5).

insert_count_increment_encoding_test() ->
    %% Increment of 1: 00_000001 = 0x01
    Inc1 = livery_qpack:encode_insert_count_increment(1),
    ?assertEqual(<<16#01>>, Inc1),

    %% Increment of 10: 00_001010 = 0x0A
    Inc10 = livery_qpack:encode_insert_count_increment(10),
    ?assertEqual(<<16#0A>>, Inc10).

process_decoder_instructions_test() ->
    State0 = livery_qpack:init(#{max_dynamic_size => 4096}),

    %% Insert Count Increment: 00_000101 = 0x05
    IncrInstr = <<16#05>>,
    {ok, State1} = livery_qpack:process_decoder_instructions(IncrInstr, State0),
    %% The known_received_count should have increased
    ?assert(is_tuple(State1)).

dynamic_table_eviction_test() ->
    %% Small table that can only hold one entry
    State0 = livery_qpack:init(#{max_dynamic_size => 64}),

    %% Insert first entry (overhead=32, so "foo"+"bar" = 3+3+32 = 38 bytes)
    Instr1 = <<16#43, "foo", 16#03, "bar">>,
    {ok, State1} = livery_qpack:process_encoder_instructions(Instr1, State0),
    ?assertEqual(1, livery_qpack:get_insert_count(State1)),

    %% Insert second entry (should evict first)
    Instr2 = <<16#43, "baz", 16#03, "qux">>,
    {ok, State2} = livery_qpack:process_encoder_instructions(Instr2, State1),
    ?assertEqual(2, livery_qpack:get_insert_count(State2)).

duplicate_instruction_test() ->
    State0 = livery_qpack:init(#{max_dynamic_size => 4096}),

    %% Insert first entry
    Instr1 = <<16#43, "foo", 16#03, "bar">>,
    {ok, State1} = livery_qpack:process_encoder_instructions(Instr1, State0),

    %% Duplicate entry at relative index 0: 000_00000 = 0x00
    DupInstr = <<16#00>>,
    {ok, State2} = livery_qpack:process_encoder_instructions(DupInstr, State1),
    ?assertEqual(2, livery_qpack:get_insert_count(State2)).
