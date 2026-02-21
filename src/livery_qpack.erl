%% @doc QPACK header compression for HTTP/3 (RFC 9204).
%%
%% Optimized for server-side use:
%% - Static table with O(1) map lookups
%% - Static table as tuple for O(1) index access
%% - Huffman decoding with lookup table
-module(livery_qpack).

-export([
    encode/1,
    encode/2,
    decode/1,
    decode/2,
    init/0,
    init/1,
    %% Dynamic table management
    set_dynamic_capacity/2,
    get_dynamic_capacity/1,
    get_insert_count/1,
    %% Encoder stream processing (instructions FROM encoder)
    process_encoder_instructions/2,
    %% Decoder stream processing (instructions FROM decoder)
    process_decoder_instructions/2,
    %% Generate instructions for encoder stream
    get_encoder_instructions/1,
    clear_encoder_instructions/1,
    %% Generate acknowledgment for decoder stream
    encode_section_ack/1,
    encode_insert_count_increment/1
]).

%% Entry overhead per RFC 9204 Section 3.2.1
-define(ENTRY_OVERHEAD, 32).

%% State record for stateful encoding/decoding
-record(qpack_state, {
    %% Dynamic table configuration
    use_dynamic = false :: boolean(),
    %% Dynamic table - maps for O(1) lookup
    dyn_field_index = #{} :: #{header() => pos_integer()},
    dyn_name_index = #{} :: #{binary() => pos_integer()},
    %% Dynamic table entries: [{AbsoluteIndex, {Name, Value}, Size}]
    dyn_entries = [] :: [{pos_integer(), header(), non_neg_integer()}],
    dyn_size = 0 :: non_neg_integer(),
    dyn_max_size = 0 :: non_neg_integer(),
    %% Insert count (absolute index for next entry)
    insert_count = 0 :: non_neg_integer(),
    %% Known received count - decoder has acked up to this
    known_received_count = 0 :: non_neg_integer(),
    %% Pending encoder instructions to send
    encoder_instructions = [] :: [binary()],
    %% Required insert count for last encoded block
    last_ric = 0 :: non_neg_integer()
}).

-opaque state() :: #qpack_state{}.
-export_type([state/0]).

-type header() :: {binary(), binary()}.

%%====================================================================
%% Static Table (RFC 9204 Appendix A) - O(1) Access
%%====================================================================

%% Static table as tuple for O(1) index access
-define(STATIC_TABLE, {
    %% 0-14
    {<<":authority">>, undefined},
    {<<":path">>, <<"/">>},
    {<<":age">>, <<"0">>},
    {<<"content-disposition">>, undefined},
    {<<"content-length">>, <<"0">>},
    {<<"cookie">>, undefined},
    {<<"date">>, undefined},
    {<<"etag">>, undefined},
    {<<"if-modified-since">>, undefined},
    {<<"if-none-match">>, undefined},
    {<<"last-modified">>, undefined},
    {<<"link">>, undefined},
    {<<"location">>, undefined},
    {<<"referer">>, undefined},
    {<<"set-cookie">>, undefined},
    %% 15-29
    {<<":method">>, <<"CONNECT">>},
    {<<":method">>, <<"DELETE">>},
    {<<":method">>, <<"GET">>},
    {<<":method">>, <<"HEAD">>},
    {<<":method">>, <<"OPTIONS">>},
    {<<":method">>, <<"POST">>},
    {<<":method">>, <<"PUT">>},
    {<<":scheme">>, <<"http">>},
    {<<":scheme">>, <<"https">>},
    {<<":status">>, <<"103">>},
    {<<":status">>, <<"200">>},
    {<<":status">>, <<"304">>},
    {<<":status">>, <<"404">>},
    {<<":status">>, <<"503">>},
    {<<"accept">>, <<"*/*">>},
    %% 30-44
    {<<"accept">>, <<"application/dns-message">>},
    {<<"accept-encoding">>, <<"gzip, deflate, br">>},
    {<<"accept-ranges">>, <<"bytes">>},
    {<<"access-control-allow-headers">>, <<"cache-control">>},
    {<<"access-control-allow-headers">>, <<"content-type">>},
    {<<"access-control-allow-origin">>, <<"*">>},
    {<<"cache-control">>, <<"max-age=0">>},
    {<<"cache-control">>, <<"max-age=2592000">>},
    {<<"cache-control">>, <<"max-age=604800">>},
    {<<"cache-control">>, <<"no-cache">>},
    {<<"cache-control">>, <<"no-store">>},
    {<<"cache-control">>, <<"public, max-age=31536000">>},
    {<<"content-encoding">>, <<"br">>},
    {<<"content-encoding">>, <<"gzip">>},
    {<<"content-type">>, <<"application/dns-message">>},
    %% 45-59
    {<<"content-type">>, <<"application/javascript">>},
    {<<"content-type">>, <<"application/json">>},
    {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
    {<<"content-type">>, <<"image/gif">>},
    {<<"content-type">>, <<"image/jpeg">>},
    {<<"content-type">>, <<"image/png">>},
    {<<"content-type">>, <<"text/css">>},
    {<<"content-type">>, <<"text/html; charset=utf-8">>},
    {<<"content-type">>, <<"text/plain">>},
    {<<"content-type">>, <<"text/plain;charset=utf-8">>},
    {<<"range">>, <<"bytes=0-">>},
    {<<"strict-transport-security">>, <<"max-age=31536000">>},
    {<<"strict-transport-security">>, <<"max-age=31536000; includesubdomains">>},
    {<<"strict-transport-security">>, <<"max-age=31536000; includesubdomains; preload">>},
    {<<"vary">>, <<"accept-encoding">>},
    %% 60-74
    {<<"vary">>, <<"origin">>},
    {<<"x-content-type-options">>, <<"nosniff">>},
    {<<"x-xss-protection">>, <<"1; mode=block">>},
    {<<":status">>, <<"100">>},
    {<<":status">>, <<"204">>},
    {<<":status">>, <<"206">>},
    {<<":status">>, <<"302">>},
    {<<":status">>, <<"400">>},
    {<<":status">>, <<"403">>},
    {<<":status">>, <<"421">>},
    {<<":status">>, <<"425">>},
    {<<":status">>, <<"500">>},
    {<<"accept-language">>, undefined},
    {<<"access-control-allow-credentials">>, <<"FALSE">>},
    {<<"access-control-allow-credentials">>, <<"TRUE">>},
    %% 75-89
    {<<"access-control-allow-headers">>, <<"*">>},
    {<<"access-control-allow-methods">>, <<"get">>},
    {<<"access-control-allow-methods">>, <<"get, post, options">>},
    {<<"access-control-allow-methods">>, <<"options">>},
    {<<"access-control-expose-headers">>, <<"content-length">>},
    {<<"access-control-request-headers">>, <<"content-type">>},
    {<<"access-control-request-method">>, <<"get">>},
    {<<"access-control-request-method">>, <<"post">>},
    {<<"alt-svc">>, <<"clear">>},
    {<<"authorization">>, undefined},
    {<<"content-security-policy">>, <<"script-src 'none'; object-src 'none'; base-uri 'none'">>},
    {<<"early-data">>, <<"1">>},
    {<<"expect-ct">>, undefined},
    {<<"forwarded">>, undefined},
    {<<"if-range">>, undefined},
    %% 90-98
    {<<"origin">>, undefined},
    {<<"purpose">>, <<"prefetch">>},
    {<<"server">>, undefined},
    {<<"timing-allow-origin">>, <<"*">>},
    {<<"upgrade-insecure-requests">>, <<"1">>},
    {<<"user-agent">>, undefined},
    {<<"x-forwarded-for">>, undefined},
    {<<"x-frame-options">>, <<"deny">>},
    {<<"x-frame-options">>, <<"sameorigin">>}
}).

%% Static table field map for O(1) exact match lookup
-define(STATIC_FIELD_MAP, #{
    {<<":path">>, <<"/">>} => 1,
    {<<":age">>, <<"0">>} => 2,
    {<<"content-length">>, <<"0">>} => 4,
    {<<":method">>, <<"CONNECT">>} => 15,
    {<<":method">>, <<"DELETE">>} => 16,
    {<<":method">>, <<"GET">>} => 17,
    {<<":method">>, <<"HEAD">>} => 18,
    {<<":method">>, <<"OPTIONS">>} => 19,
    {<<":method">>, <<"POST">>} => 20,
    {<<":method">>, <<"PUT">>} => 21,
    {<<":scheme">>, <<"http">>} => 22,
    {<<":scheme">>, <<"https">>} => 23,
    {<<":status">>, <<"103">>} => 24,
    {<<":status">>, <<"200">>} => 25,
    {<<":status">>, <<"304">>} => 26,
    {<<":status">>, <<"404">>} => 27,
    {<<":status">>, <<"503">>} => 28,
    {<<"accept">>, <<"*/*">>} => 29,
    {<<"accept">>, <<"application/dns-message">>} => 30,
    {<<"accept-encoding">>, <<"gzip, deflate, br">>} => 31,
    {<<"accept-ranges">>, <<"bytes">>} => 32,
    {<<"access-control-allow-headers">>, <<"cache-control">>} => 33,
    {<<"access-control-allow-headers">>, <<"content-type">>} => 34,
    {<<"access-control-allow-origin">>, <<"*">>} => 35,
    {<<"cache-control">>, <<"max-age=0">>} => 36,
    {<<"cache-control">>, <<"max-age=2592000">>} => 37,
    {<<"cache-control">>, <<"max-age=604800">>} => 38,
    {<<"cache-control">>, <<"no-cache">>} => 39,
    {<<"cache-control">>, <<"no-store">>} => 40,
    {<<"cache-control">>, <<"public, max-age=31536000">>} => 41,
    {<<"content-encoding">>, <<"br">>} => 42,
    {<<"content-encoding">>, <<"gzip">>} => 43,
    {<<"content-type">>, <<"application/dns-message">>} => 44,
    {<<"content-type">>, <<"application/javascript">>} => 45,
    {<<"content-type">>, <<"application/json">>} => 46,
    {<<"content-type">>, <<"application/x-www-form-urlencoded">>} => 47,
    {<<"content-type">>, <<"image/gif">>} => 48,
    {<<"content-type">>, <<"image/jpeg">>} => 49,
    {<<"content-type">>, <<"image/png">>} => 50,
    {<<"content-type">>, <<"text/css">>} => 51,
    {<<"content-type">>, <<"text/html; charset=utf-8">>} => 52,
    {<<"content-type">>, <<"text/plain">>} => 53,
    {<<"content-type">>, <<"text/plain;charset=utf-8">>} => 54,
    {<<"range">>, <<"bytes=0-">>} => 55,
    {<<"strict-transport-security">>, <<"max-age=31536000">>} => 56,
    {<<"strict-transport-security">>, <<"max-age=31536000; includesubdomains">>} => 57,
    {<<"strict-transport-security">>, <<"max-age=31536000; includesubdomains; preload">>} => 58,
    {<<"vary">>, <<"accept-encoding">>} => 59,
    {<<"vary">>, <<"origin">>} => 60,
    {<<"x-content-type-options">>, <<"nosniff">>} => 61,
    {<<"x-xss-protection">>, <<"1; mode=block">>} => 62,
    {<<":status">>, <<"100">>} => 63,
    {<<":status">>, <<"204">>} => 64,
    {<<":status">>, <<"206">>} => 65,
    {<<":status">>, <<"302">>} => 66,
    {<<":status">>, <<"400">>} => 67,
    {<<":status">>, <<"403">>} => 68,
    {<<":status">>, <<"421">>} => 69,
    {<<":status">>, <<"425">>} => 70,
    {<<":status">>, <<"500">>} => 71,
    {<<"access-control-allow-credentials">>, <<"FALSE">>} => 73,
    {<<"access-control-allow-credentials">>, <<"TRUE">>} => 74,
    {<<"access-control-allow-headers">>, <<"*">>} => 75,
    {<<"access-control-allow-methods">>, <<"get">>} => 76,
    {<<"access-control-allow-methods">>, <<"get, post, options">>} => 77,
    {<<"access-control-allow-methods">>, <<"options">>} => 78,
    {<<"access-control-expose-headers">>, <<"content-length">>} => 79,
    {<<"access-control-request-headers">>, <<"content-type">>} => 80,
    {<<"access-control-request-method">>, <<"get">>} => 81,
    {<<"access-control-request-method">>, <<"post">>} => 82,
    {<<"alt-svc">>, <<"clear">>} => 83,
    {<<"content-security-policy">>, <<"script-src 'none'; object-src 'none'; base-uri 'none'">>} => 85,
    {<<"early-data">>, <<"1">>} => 86,
    {<<"purpose">>, <<"prefetch">>} => 91,
    {<<"timing-allow-origin">>, <<"*">>} => 93,
    {<<"upgrade-insecure-requests">>, <<"1">>} => 94,
    {<<"x-frame-options">>, <<"deny">>} => 97,
    {<<"x-frame-options">>, <<"sameorigin">>} => 98
}).

%% Static table name map for O(1) name-only lookup
-define(STATIC_NAME_MAP, #{
    <<":authority">> => 0,
    <<":path">> => 1,
    <<":age">> => 2,
    <<"content-disposition">> => 3,
    <<"content-length">> => 4,
    <<"cookie">> => 5,
    <<"date">> => 6,
    <<"etag">> => 7,
    <<"if-modified-since">> => 8,
    <<"if-none-match">> => 9,
    <<"last-modified">> => 10,
    <<"link">> => 11,
    <<"location">> => 12,
    <<"referer">> => 13,
    <<"set-cookie">> => 14,
    <<":method">> => 15,
    <<":scheme">> => 22,
    <<":status">> => 24,
    <<"accept">> => 29,
    <<"accept-encoding">> => 31,
    <<"accept-ranges">> => 32,
    <<"access-control-allow-headers">> => 33,
    <<"access-control-allow-origin">> => 35,
    <<"cache-control">> => 36,
    <<"content-encoding">> => 42,
    <<"content-type">> => 44,
    <<"range">> => 55,
    <<"strict-transport-security">> => 56,
    <<"vary">> => 59,
    <<"x-content-type-options">> => 61,
    <<"x-xss-protection">> => 62,
    <<"accept-language">> => 72,
    <<"access-control-allow-credentials">> => 73,
    <<"access-control-allow-methods">> => 76,
    <<"access-control-expose-headers">> => 79,
    <<"access-control-request-headers">> => 80,
    <<"access-control-request-method">> => 81,
    <<"alt-svc">> => 83,
    <<"authorization">> => 84,
    <<"content-security-policy">> => 85,
    <<"early-data">> => 86,
    <<"expect-ct">> => 87,
    <<"forwarded">> => 88,
    <<"if-range">> => 89,
    <<"origin">> => 90,
    <<"purpose">> => 91,
    <<"server">> => 92,
    <<"timing-allow-origin">> => 93,
    <<"upgrade-insecure-requests">> => 94,
    <<"user-agent">> => 95,
    <<"x-forwarded-for">> => 96,
    <<"x-frame-options">> => 97
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Initialize QPACK state (static-only mode).
-spec init() -> state().
init() ->
    #qpack_state{}.

%% @doc Initialize QPACK state with options.
%% Options:
%%   max_dynamic_size - Enable dynamic table with given max size (default: 0 = disabled)
-spec init(#{atom() => term()}) -> state().
init(Opts) ->
    MaxDynSize = maps:get(max_dynamic_size, Opts, 0),
    #qpack_state{
        use_dynamic = MaxDynSize > 0,
        dyn_max_size = MaxDynSize
    }.

%% @doc Encode headers using QPACK (stateless, static-only).
-spec encode([header()]) -> binary().
encode(Headers) ->
    {Encoded, _} = encode(Headers, #qpack_state{}),
    Encoded.

%% @doc Encode headers using QPACK with state.
-spec encode([header()], state()) -> {binary(), state()}.
encode(Headers, State) ->
    %% First pass: encode headers and track max dynamic table index referenced
    {EncodedHeaders, NewState, MaxRefIndex} = encode_headers_tracking(Headers, State, <<>>, -1),

    %% Calculate Required Insert Count (RIC)
    %% RIC = MaxRefIndex + 1 if any dynamic entry was referenced, else 0
    RIC = case MaxRefIndex >= 0 of
        true -> MaxRefIndex + 1;
        false -> 0
    end,

    %% Encode prefix: Required Insert Count + Base (Section 4.5.1)
    %% For simplicity, we use Base = RIC (Delta Base = 0, S = 0)
    RICEncoded = encode_ric(RIC, State#qpack_state.dyn_max_size),
    BaseEncoded = 0,  %% S=0, DeltaBase=0 means Base = RIC
    Prefix = <<RICEncoded, BaseEncoded>>,

    {<<Prefix/binary, EncodedHeaders/binary>>, NewState#qpack_state{last_ric = RIC}}.

%% Encode Required Insert Count per Section 4.5.1.1
%% ERIC = (RIC mod (2 * MaxEntries)) + 1
encode_ric(0, _MaxSize) ->
    0;
encode_ric(RIC, MaxSize) ->
    MaxEntries = max(1, MaxSize div 32),  %% Entry overhead is 32
    ERIC = (RIC rem (2 * MaxEntries)) + 1,
    ERIC.

%% @doc Decode QPACK-encoded headers (stateless).
-spec decode(binary()) -> {ok, [header()]} | {error, term()}.
decode(Data) ->
    {Result, _} = decode(Data, #qpack_state{}),
    Result.

%% @doc Decode QPACK-encoded headers with state.
-spec decode(binary(), state()) -> {{ok, [header()]} | {error, term()}, state()}.
decode(Data, State) ->
    try
        {{RIC, _Base}, Rest} = decode_prefix(Data),
        {Headers, NewState} = decode_headers(Rest, RIC, State, []),
        {{ok, Headers}, NewState}
    catch
        _:Reason ->
            {{error, Reason}, State}
    end.

%%====================================================================
%% Dynamic Table Management API
%%====================================================================

%% @doc Set dynamic table capacity.
%% This generates a Set Dynamic Table Capacity instruction for the encoder stream.
-spec set_dynamic_capacity(non_neg_integer(), state()) -> state().
set_dynamic_capacity(Capacity, State) ->
    %% Generate instruction: 001xxxxx
    Instruction = encode_prefixed_int(Capacity, 5, 2#001),
    %% Update state and evict if needed
    State1 = State#qpack_state{
        dyn_max_size = Capacity,
        use_dynamic = Capacity > 0,
        encoder_instructions = [Instruction | State#qpack_state.encoder_instructions]
    },
    evict_to_fit(0, State1).

%% @doc Get dynamic table capacity.
-spec get_dynamic_capacity(state()) -> non_neg_integer().
get_dynamic_capacity(#qpack_state{dyn_max_size = MaxSize}) ->
    MaxSize.

%% @doc Get current insert count.
-spec get_insert_count(state()) -> non_neg_integer().
get_insert_count(#qpack_state{insert_count = IC}) ->
    IC.

%% @doc Get pending encoder instructions.
%% These should be sent on the encoder stream.
-spec get_encoder_instructions(state()) -> binary().
get_encoder_instructions(#qpack_state{encoder_instructions = Instructions}) ->
    iolist_to_binary(lists:reverse(Instructions)).

%% @doc Clear pending encoder instructions after sending.
-spec clear_encoder_instructions(state()) -> state().
clear_encoder_instructions(State) ->
    State#qpack_state{encoder_instructions = []}.

%% @doc Encode a Section Acknowledgment for the decoder stream.
%% StreamId should be the stream where headers were decoded.
-spec encode_section_ack(non_neg_integer()) -> binary().
encode_section_ack(StreamId) ->
    %% Section Acknowledgment: 1xxxxxxx
    encode_prefixed_int(StreamId, 7, 2#1).

%% @doc Encode an Insert Count Increment for the decoder stream.
-spec encode_insert_count_increment(non_neg_integer()) -> binary().
encode_insert_count_increment(Increment) ->
    %% Insert Count Increment: 00xxxxxx
    encode_prefixed_int(Increment, 6, 2#00).

%%====================================================================
%% Encoder Stream Processing
%%====================================================================

%% @doc Process encoder instructions from the peer's encoder stream.
%% Updates the dynamic table based on received instructions.
-spec process_encoder_instructions(binary(), state()) -> {ok, state()} | {error, term()}.
process_encoder_instructions(<<>>, State) ->
    {ok, State};
process_encoder_instructions(Data, State) ->
    case decode_encoder_instruction(Data) of
        {ok, Instruction, Rest} ->
            case apply_encoder_instruction(Instruction, State) of
                {ok, State1} ->
                    process_encoder_instructions(Rest, State1);
                {error, _} = Error ->
                    Error
            end;
        incomplete ->
            %% Need more data - this shouldn't happen in normal use
            %% as we process complete instructions
            {ok, State};
        {error, _} = Error ->
            Error
    end.

decode_encoder_instruction(<<2#1:1, S:1, _:6, _/binary>> = Data) ->
    %% Insert With Name Reference: 1Sxxxxxx
    decode_insert_with_name_ref(Data, S);
decode_encoder_instruction(<<2#01:2, H:1, _:5, _/binary>> = Data) ->
    %% Insert With Literal Name: 01Hxxxxx
    decode_insert_literal_name(Data, H);
decode_encoder_instruction(<<2#000:3, _:5, _/binary>> = Data) ->
    %% Duplicate: 000xxxxx
    decode_duplicate(Data);
decode_encoder_instruction(<<2#001:3, _:5, _/binary>> = Data) ->
    %% Set Dynamic Table Capacity: 001xxxxx
    decode_set_capacity(Data);
decode_encoder_instruction(<<>>) ->
    incomplete;
decode_encoder_instruction(_) ->
    {error, invalid_encoder_instruction}.

decode_insert_with_name_ref(Data, Static) ->
    %% Format: 1Sxxxxxx where S=1 for static, S=0 for dynamic
    %% First byte has 6-bit index with prefix
    <<FirstByte, Rest0/binary>> = Data,
    IndexBits = FirstByte band 16#3F,
    {Index, Rest1} = case IndexBits < 63 of
        true -> {IndexBits, Rest0};
        false -> decode_multi_byte_int(Rest0, IndexBits, 0)
    end,
    %% Decode value
    case decode_string(Rest1) of
        {Value, Rest2} ->
            {ok, {insert_name_ref, Static, Index, Value}, Rest2};
        _ ->
            incomplete
    end.

decode_insert_literal_name(Data, H) ->
    <<_:3, NameLenBits:5, Rest0/binary>> = Data,
    {NameLen, Rest1} = case NameLenBits < 31 of
        true -> {NameLenBits, Rest0};
        false -> decode_multi_byte_int(Rest0, NameLenBits, 0)
    end,
    case byte_size(Rest1) >= NameLen of
        true ->
            {Name, Rest2} = decode_string_with_huffman(H, NameLen, Rest1),
            case decode_string(Rest2) of
                {Value, Rest3} ->
                    {ok, {insert_literal, Name, Value}, Rest3};
                _ ->
                    incomplete
            end;
        false ->
            incomplete
    end.

decode_duplicate(Data) ->
    <<_:3, IndexBits:5, Rest0/binary>> = Data,
    {Index, Rest1} = case IndexBits < 31 of
        true -> {IndexBits, Rest0};
        false -> decode_multi_byte_int(Rest0, IndexBits, 0)
    end,
    {ok, {duplicate, Index}, Rest1}.

decode_set_capacity(Data) ->
    <<_:3, CapBits:5, Rest0/binary>> = Data,
    {Capacity, Rest1} = case CapBits < 31 of
        true -> {CapBits, Rest0};
        false -> decode_multi_byte_int(Rest0, CapBits, 0)
    end,
    {ok, {set_capacity, Capacity}, Rest1}.

apply_encoder_instruction({insert_name_ref, 1, Index, Value}, State) ->
    %% Static table reference
    case get_static_entry(Index) of
        {Name, _} ->
            insert_entry(Name, Value, State);
        _ ->
            {error, invalid_static_index}
    end;
apply_encoder_instruction({insert_name_ref, 0, Index, Value}, State) ->
    %% Dynamic table reference
    case get_dynamic_entry_by_relative(Index, State) of
        {Name, _} ->
            insert_entry(Name, Value, State);
        undefined ->
            {error, invalid_dynamic_index}
    end;
apply_encoder_instruction({insert_literal, Name, Value}, State) ->
    insert_entry(Name, Value, State);
apply_encoder_instruction({duplicate, Index}, State) ->
    case get_dynamic_entry_by_relative(Index, State) of
        {Name, Value} ->
            insert_entry(Name, Value, State);
        undefined ->
            {error, invalid_dynamic_index}
    end;
apply_encoder_instruction({set_capacity, Capacity}, State) ->
    {ok, evict_to_fit(0, State#qpack_state{dyn_max_size = Capacity, use_dynamic = Capacity > 0})}.

%%====================================================================
%% Decoder Stream Processing
%%====================================================================

%% @doc Process decoder instructions from the peer's decoder stream.
%% Updates known_received_count based on acknowledgments.
-spec process_decoder_instructions(binary(), state()) -> {ok, state()} | {error, term()}.
process_decoder_instructions(<<>>, State) ->
    {ok, State};
process_decoder_instructions(Data, State) ->
    case decode_decoder_instruction(Data) of
        {ok, Instruction, Rest} ->
            State1 = apply_decoder_instruction(Instruction, State),
            process_decoder_instructions(Rest, State1);
        incomplete ->
            {ok, State};
        {error, _} = Error ->
            Error
    end.

decode_decoder_instruction(<<2#1:1, _:7, _/binary>> = Data) ->
    %% Section Acknowledgment: 1xxxxxxx
    {StreamId, Rest} = decode_prefixed_int(Data, 7),
    {ok, {section_ack, StreamId}, Rest};
decode_decoder_instruction(<<2#01:2, _:6, _/binary>> = Data) ->
    %% Stream Cancellation: 01xxxxxx
    {StreamId, Rest} = decode_prefixed_int(Data, 6),
    {ok, {stream_cancel, StreamId}, Rest};
decode_decoder_instruction(<<2#00:2, _:6, _/binary>> = Data) ->
    %% Insert Count Increment: 00xxxxxx
    {Increment, Rest} = decode_prefixed_int(Data, 6),
    {ok, {insert_count_increment, Increment}, Rest};
decode_decoder_instruction(<<>>) ->
    incomplete;
decode_decoder_instruction(_) ->
    {error, invalid_decoder_instruction}.

apply_decoder_instruction({section_ack, _StreamId}, State) ->
    %% For now, just track that something was acked
    %% Full implementation would track per-stream RIC
    State;
apply_decoder_instruction({stream_cancel, _StreamId}, State) ->
    %% Stream was cancelled, cleanup any blocked state
    State;
apply_decoder_instruction({insert_count_increment, Increment}, State) ->
    NewKRC = State#qpack_state.known_received_count + Increment,
    State#qpack_state{known_received_count = NewKRC}.

%%====================================================================
%% Internal - Encoding
%%====================================================================

%% Encode headers while tracking maximum dynamic table index referenced
encode_headers_tracking([], State, Acc, MaxRef) ->
    {Acc, State, MaxRef};
encode_headers_tracking([Header | Rest], State, Acc, MaxRef) ->
    {Encoded, NewState, RefIndex} = encode_header_tracking(Header, State),
    NewMaxRef = case RefIndex of
        none -> MaxRef;
        Idx -> max(MaxRef, Idx)
    end,
    encode_headers_tracking(Rest, NewState, <<Acc/binary, Encoded/binary>>, NewMaxRef).

%% Encode header with tracking of referenced dynamic index
encode_header_tracking({Name, Value}, #qpack_state{use_dynamic = true} = State) ->
    case find_dynamic_match(Name, Value, State) of
        {exact, AbsIndex} ->
            RelIndex = State#qpack_state.insert_count - AbsIndex - 1,
            {encode_indexed_dynamic(RelIndex), State, AbsIndex};
        {name, AbsIndex} ->
            RelIndex = State#qpack_state.insert_count - AbsIndex - 1,
            {encode_literal_with_dynamic_name_ref(RelIndex, Value), State, AbsIndex};
        none ->
            {Encoded, NewState} = encode_header_static({Name, Value}, State),
            {Encoded, NewState, none}
    end;
encode_header_tracking({Name, Value}, State) ->
    {Encoded, NewState} = encode_header_static({Name, Value}, State),
    {Encoded, NewState, none}.

%% Encode using static table or literal
encode_header_static({Name, Value}, State) ->
    case find_static_match(Name, Value) of
        {exact, Index} ->
            %% Indexed Field Line (static) - 11xxxxxx
            {encode_indexed_static(Index), State};
        {name, Index} ->
            %% Literal Field Line With Name Reference (static)
            {encode_literal_with_name_ref(Index, Value), State};
        none ->
            %% Literal Field Line With Literal Name
            {encode_literal(Name, Value), State}
    end.

%% Indexed Field Line - 11xxxxxx for static
encode_indexed_static(Index) ->
    encode_prefixed_int(Index, 6, 2#11).

%% Indexed Field Line - 10xxxxxx for dynamic
encode_indexed_dynamic(RelIndex) ->
    encode_prefixed_int(RelIndex, 6, 2#10).

%% Literal with name reference - 0101xxxx (N=0, T=1 for static)
encode_literal_with_name_ref(Index, Value) ->
    NameRef = encode_prefixed_int(Index, 4, 2#0101),
    ValueEnc = encode_string(Value),
    <<NameRef/binary, ValueEnc/binary>>.

%% Literal with dynamic name reference - 0100xxxx (N=0, T=0 for dynamic)
encode_literal_with_dynamic_name_ref(RelIndex, Value) ->
    NameRef = encode_prefixed_int(RelIndex, 4, 2#0100),
    ValueEnc = encode_string(Value),
    <<NameRef/binary, ValueEnc/binary>>.

%% Literal with literal name - 0010xxxx (N=0, H=0 for no huffman)
encode_literal(Name, Value) ->
    NameLen = byte_size(Name),
    ValueEnc = encode_string(Value),
    case NameLen < 7 of
        true ->
            FirstByte = 2#00100000 bor NameLen,
            <<FirstByte, Name/binary, ValueEnc/binary>>;
        false ->
            FirstByte = 2#00100111,
            LenCont = encode_multi_byte_int(NameLen - 7),
            <<FirstByte, LenCont/binary, Name/binary, ValueEnc/binary>>
    end.

encode_string(Str) ->
    Len = byte_size(Str),
    LenEnc = encode_prefixed_int(Len, 7, 0),
    <<LenEnc/binary, Str/binary>>.

encode_prefixed_int(Value, PrefixBits, Prefix) when Value < (1 bsl PrefixBits) - 1 ->
    <<(Prefix bsl PrefixBits bor Value)>>;
encode_prefixed_int(Value, PrefixBits, Prefix) ->
    MaxPrefix = (1 bsl PrefixBits) - 1,
    FirstByte = Prefix bsl PrefixBits bor MaxPrefix,
    Remaining = Value - MaxPrefix,
    <<FirstByte, (encode_multi_byte_int(Remaining))/binary>>.

encode_multi_byte_int(Value) when Value < 128 ->
    <<Value>>;
encode_multi_byte_int(Value) ->
    <<(128 bor (Value band 127)), (encode_multi_byte_int(Value bsr 7))/binary>>.

%%====================================================================
%% Internal - Decoding
%%====================================================================

decode_prefix(<<ERIC, Base, Rest/binary>>) ->
    %% ERIC (Encoded Required Insert Count) per Section 4.5.1.1
    %% Decoding: if ERIC = 0, RIC = 0
    %% Otherwise: RIC = ERIC - 1 (for simple synchronized case)
    RIC = case ERIC of
        0 -> 0;
        _ -> ERIC - 1
    end,
    {{RIC, Base}, Rest};
decode_prefix(_) ->
    throw(invalid_prefix).

%% Decode headers with Required Insert Count (RIC) and Base from prefix
decode_headers(<<>>, _RIC, State, Acc) ->
    {lists:reverse(Acc), State};
decode_headers(<<2#11:2, _:6, _/binary>> = Data, RIC, State, Acc) ->
    %% Indexed Field Line (static) - 11xxxxxx
    {Index, Rest} = decode_prefixed_int(Data, 6),
    Header = get_static_entry(Index),
    decode_headers(Rest, RIC, State, [Header | Acc]);
decode_headers(<<2#10:2, _:6, _/binary>> = Data, RIC, State, Acc) ->
    %% Indexed Field Line (dynamic) - 10xxxxxx
    {RelIndex, Rest} = decode_prefixed_int(Data, 6),
    %% Convert relative index to absolute using Base (which equals RIC for non-post-base)
    AbsIndex = RIC - RelIndex - 1,
    case get_dynamic_entry_by_absolute(AbsIndex, State) of
        {Name, Value} ->
            decode_headers(Rest, RIC, State, [{Name, Value} | Acc]);
        undefined ->
            throw({invalid_dynamic_index, AbsIndex})
    end;
decode_headers(<<2#01:2, _N:1, T:1, _:4, _/binary>> = Data, RIC, State, Acc) ->
    %% Literal Field Line with Name Reference - 01NTxxxx
    FirstByte = hd(binary_to_list(Data)),
    IndexBits = FirstByte band 16#0F,
    <<_, Rest0/binary>> = Data,
    {Index, Rest1} = case IndexBits < 15 of
        true -> {IndexBits, Rest0};
        false -> decode_multi_byte_int(Rest0, IndexBits, 0)
    end,
    {Value, Rest2} = decode_string(Rest1),
    case T of
        1 ->
            %% Static table reference
            {Name, _} = get_static_entry(Index),
            decode_headers(Rest2, RIC, State, [{Name, Value} | Acc]);
        0 ->
            %% Dynamic table reference
            AbsIndex = RIC - Index - 1,
            case get_dynamic_entry_by_absolute(AbsIndex, State) of
                {Name, _} ->
                    decode_headers(Rest2, RIC, State, [{Name, Value} | Acc]);
                undefined ->
                    throw({invalid_dynamic_index, AbsIndex})
            end
    end;
decode_headers(<<2#0010:4, H:1, NameLenPrefix:3, Rest0/binary>>, RIC, State, Acc) ->
    %% Literal with literal name - 0010Hxxx
    {NameLen, Rest1} = case NameLenPrefix < 7 of
        true -> {NameLenPrefix, Rest0};
        false -> decode_multi_byte_int(Rest0, NameLenPrefix, 0)
    end,
    {Name, Rest2} = decode_string_with_huffman(H, NameLen, Rest1),
    {Value, Rest3} = decode_string(Rest2),
    decode_headers(Rest3, RIC, State, [{Name, Value} | Acc]);
decode_headers(<<2#0011:4, H:1, NameLenPrefix:3, Rest0/binary>>, RIC, State, Acc) ->
    %% Literal with literal name, N=1 - 0011Hxxx
    {NameLen, Rest1} = case NameLenPrefix < 7 of
        true -> {NameLenPrefix, Rest0};
        false -> decode_multi_byte_int(Rest0, NameLenPrefix, 0)
    end,
    {Name, Rest2} = decode_string_with_huffman(H, NameLen, Rest1),
    {Value, Rest3} = decode_string(Rest2),
    decode_headers(Rest3, RIC, State, [{Name, Value} | Acc]);
decode_headers(<<2#0001:4, _:4, _/binary>> = Data, RIC, State, Acc) ->
    %% Indexed Header Field with Post-Base Index - 0001xxxx
    FirstByte = hd(binary_to_list(Data)),
    IndexBits = FirstByte band 16#0F,
    <<_, Rest0/binary>> = Data,
    {PostBaseIndex, Rest1} = case IndexBits < 15 of
        true -> {IndexBits, Rest0};
        false -> decode_multi_byte_int(Rest0, IndexBits, 0)
    end,
    %% Post-base index: AbsIndex = Base + PostBaseIndex = RIC + PostBaseIndex
    AbsIndex = RIC + PostBaseIndex,
    case get_dynamic_entry_by_absolute(AbsIndex, State) of
        {Name, Value} ->
            decode_headers(Rest1, RIC, State, [{Name, Value} | Acc]);
        undefined ->
            throw({invalid_dynamic_index, AbsIndex})
    end;
decode_headers(<<2#0000:4, _N:1, _:3, _/binary>> = Data, RIC, State, Acc) ->
    %% Literal with post-base name reference - 0000Nxxx
    FirstByte = hd(binary_to_list(Data)),
    IndexBits = FirstByte band 16#07,
    <<_, Rest0/binary>> = Data,
    {PostBaseIndex, Rest1} = case IndexBits < 7 of
        true -> {IndexBits, Rest0};
        false -> decode_multi_byte_int(Rest0, IndexBits, 0)
    end,
    {Value, Rest2} = decode_string(Rest1),
    AbsIndex = RIC + PostBaseIndex,
    case get_dynamic_entry_by_absolute(AbsIndex, State) of
        {Name, _} ->
            decode_headers(Rest2, RIC, State, [{Name, Value} | Acc]);
        undefined ->
            throw({invalid_dynamic_index, AbsIndex})
    end;
decode_headers(<<Byte, _/binary>>, _RIC, _State, _Acc) ->
    throw({unknown_instruction, Byte}).

decode_prefixed_int(Data, PrefixBits) ->
    MaxPrefix = (1 bsl PrefixBits) - 1,
    <<First, Rest/binary>> = Data,
    Value = First band MaxPrefix,
    case Value < MaxPrefix of
        true ->
            {Value, Rest};
        false ->
            decode_multi_byte_int(Rest, Value, 0)
    end.

decode_multi_byte_int(<<Byte, Rest/binary>>, Acc, Shift) ->
    NewAcc = Acc + ((Byte band 127) bsl Shift),
    case Byte band 128 of
        0 -> {NewAcc, Rest};
        _ -> decode_multi_byte_int(Rest, NewAcc, Shift + 7)
    end.

decode_string(<<0:1, 127:7, Rest/binary>>) ->
    {ActualLen, Rest2} = decode_multi_byte_int(Rest, 127, 0),
    case byte_size(Rest2) >= ActualLen of
        true ->
            <<Str:ActualLen/binary, Rest3/binary>> = Rest2,
            {Str, Rest3};
        false ->
            throw({invalid_string, need_more_data})
    end;
decode_string(<<1:1, 127:7, Rest/binary>>) ->
    {ActualLen, Rest2} = decode_multi_byte_int(Rest, 127, 0),
    case byte_size(Rest2) >= ActualLen of
        true ->
            <<Encoded:ActualLen/binary, Rest3/binary>> = Rest2,
            {Decoded, _} = dec_huffman(Encoded, ActualLen),
            {Decoded, Rest3};
        false ->
            throw({invalid_string, need_more_data})
    end;
decode_string(<<0:1, Len:7, Rest/binary>>) when byte_size(Rest) >= Len ->
    <<Str:Len/binary, Rest2/binary>> = Rest,
    {Str, Rest2};
decode_string(<<1:1, Len:7, Rest/binary>>) when byte_size(Rest) >= Len ->
    <<Encoded:Len/binary, Rest2/binary>> = Rest,
    {Decoded, _} = dec_huffman(Encoded, Len),
    {Decoded, Rest2};
decode_string(Data) ->
    throw({invalid_string, byte_size(Data), Data}).

decode_string_with_huffman(HuffFlag, Len, Data) when byte_size(Data) >= Len ->
    <<Encoded:Len/binary, Rest/binary>> = Data,
    case HuffFlag of
        1 ->
            {Decoded, _} = dec_huffman(Encoded, Len),
            {Decoded, Rest};
        0 ->
            {Encoded, Rest}
    end;
decode_string_with_huffman(_HuffFlag, Len, Data) ->
    throw({invalid_string, need_more_data, Len, byte_size(Data)}).

%% Huffman decoding using HPACK lookup table
-include("livery_huffman_lookup.hrl").

dec_huffman(Data, Length) ->
    dec_huffman(Data, Length, 0, <<>>).

dec_huffman(<<A:4, B:4, R/bits>>, Len, Huff0, Acc) when Len > 1 ->
    {_, CharA, Huff1} = dec_huffman_lookup(Huff0, A),
    {_, CharB, Huff} = dec_huffman_lookup(Huff1, B),
    case {CharA, CharB} of
        {undefined, undefined} -> dec_huffman(R, Len - 1, Huff, Acc);
        {CharA, undefined} -> dec_huffman(R, Len - 1, Huff, <<Acc/binary, CharA>>);
        {undefined, CharB} -> dec_huffman(R, Len - 1, Huff, <<Acc/binary, CharB>>);
        {CharA, CharB} -> dec_huffman(R, Len - 1, Huff, <<Acc/binary, CharA, CharB>>)
    end;
dec_huffman(<<A:4, B:4, Rest/bits>>, 1, Huff0, Acc) ->
    {_, CharA, Huff} = dec_huffman_lookup(Huff0, A),
    case dec_huffman_lookup(Huff, B) of
        {ok, CharB, _} ->
            case {CharA, CharB} of
                {undefined, undefined} ->
                    {Acc, Rest};
                {CharA, undefined} ->
                    {<<Acc/binary, CharA>>, Rest};
                {undefined, CharB} ->
                    {<<Acc/binary, CharB>>, Rest};
                _ ->
                    {<<Acc/binary, CharA, CharB>>, Rest}
            end;
        {more, _, _} ->
            case CharA of
                undefined -> {Acc, Rest};
                _ -> {<<Acc/binary, CharA>>, Rest}
            end
    end;
dec_huffman(Rest, 0, _, <<>>) ->
    {<<>>, Rest};
dec_huffman(Rest, 0, _, Acc) ->
    {Acc, Rest}.

%%====================================================================
%% Internal - Static Table Lookup (O(1))
%%====================================================================

%% Find match in static table using maps - O(1)
find_static_match(Name, Value) ->
    Header = {Name, Value},
    case maps:find(Header, ?STATIC_FIELD_MAP) of
        {ok, Index} ->
            {exact, Index};
        error ->
            case maps:find(Name, ?STATIC_NAME_MAP) of
                {ok, Index} ->
                    {name, Index};
                error ->
                    none
            end
    end.

%% Get static table entry by index - O(1)
get_static_entry(Index) when Index >= 0, Index =< 98 ->
    element(Index + 1, ?STATIC_TABLE);
get_static_entry(Index) ->
    throw({invalid_static_index, Index}).

%%====================================================================
%% Internal - Dynamic Table Management
%%====================================================================

%% @doc Insert an entry into the dynamic table.
%% Evicts old entries if necessary to make room.
-spec insert_entry(binary(), binary(), state()) -> {ok, state()}.
insert_entry(Name, Value, State) ->
    EntrySize = entry_size(Name, Value),
    case EntrySize > State#qpack_state.dyn_max_size of
        true ->
            %% Entry too large - evict everything but don't insert
            {ok, State#qpack_state{
                dyn_entries = [],
                dyn_field_index = #{},
                dyn_name_index = #{},
                dyn_size = 0
            }};
        false ->
            %% Evict entries to make room
            State1 = evict_to_fit(EntrySize, State),
            %% Insert new entry
            AbsIndex = State1#qpack_state.insert_count,
            Header = {Name, Value},
            NewEntries = [{AbsIndex, Header, EntrySize} | State1#qpack_state.dyn_entries],
            NewFieldIndex = maps:put(Header, AbsIndex, State1#qpack_state.dyn_field_index),
            NewNameIndex = maps:put(Name, AbsIndex, State1#qpack_state.dyn_name_index),
            {ok, State1#qpack_state{
                dyn_entries = NewEntries,
                dyn_field_index = NewFieldIndex,
                dyn_name_index = NewNameIndex,
                dyn_size = State1#qpack_state.dyn_size + EntrySize,
                insert_count = AbsIndex + 1
            }}
    end.

%% @doc Calculate size of a dynamic table entry.
%% Per RFC 9204 Section 3.2.1: size = name_length + value_length + 32
-spec entry_size(binary(), binary()) -> non_neg_integer().
entry_size(Name, Value) ->
    byte_size(Name) + byte_size(Value) + ?ENTRY_OVERHEAD.

%% @doc Evict entries until there's room for an entry of the given size.
-spec evict_to_fit(non_neg_integer(), state()) -> state().
evict_to_fit(RequiredSize, #qpack_state{dyn_size = Size, dyn_max_size = MaxSize} = State)
  when Size + RequiredSize =< MaxSize ->
    State;
evict_to_fit(_RequiredSize, #qpack_state{dyn_entries = []} = State) ->
    %% No entries to evict
    State;
evict_to_fit(RequiredSize, #qpack_state{dyn_entries = Entries} = State) ->
    %% Evict oldest entry (last in list)
    {Oldest, RestEntries} = lists:split(length(Entries) - 1, Entries),
    [{AbsIndex, Header, EntrySize}] = RestEntries,
    {Name, _Value} = Header,
    NewFieldIndex = maps:remove(Header, State#qpack_state.dyn_field_index),
    %% Only remove from name index if this was the entry for that name
    NewNameIndex = case maps:get(Name, State#qpack_state.dyn_name_index, undefined) of
        AbsIndex -> maps:remove(Name, State#qpack_state.dyn_name_index);
        _ -> State#qpack_state.dyn_name_index
    end,
    State1 = State#qpack_state{
        dyn_entries = Oldest,
        dyn_field_index = NewFieldIndex,
        dyn_name_index = NewNameIndex,
        dyn_size = State#qpack_state.dyn_size - EntrySize
    },
    evict_to_fit(RequiredSize, State1).

%% @doc Get dynamic table entry by relative index.
%% Relative index 0 is the most recently inserted entry.
-spec get_dynamic_entry_by_relative(non_neg_integer(), state()) -> header() | undefined.
get_dynamic_entry_by_relative(RelIndex, #qpack_state{insert_count = IC} = State) ->
    %% Relative index 0 = most recent = IC - 1
    AbsIndex = IC - RelIndex - 1,
    get_dynamic_entry_by_absolute(AbsIndex, State).

%% @doc Get dynamic table entry by absolute index.
-spec get_dynamic_entry_by_absolute(non_neg_integer(), state()) -> header() | undefined.
get_dynamic_entry_by_absolute(AbsIndex, #qpack_state{dyn_entries = Entries}) ->
    case lists:keyfind(AbsIndex, 1, Entries) of
        {AbsIndex, Header, _Size} -> Header;
        false -> undefined
    end.

%% @doc Find a match in the dynamic table.
%% Returns {exact, AbsIndex}, {name, AbsIndex}, or none.
-spec find_dynamic_match(binary(), binary(), state()) -> {exact, non_neg_integer()} |
                                                          {name, non_neg_integer()} |
                                                          none.
find_dynamic_match(_Name, _Value, #qpack_state{use_dynamic = false}) ->
    none;
find_dynamic_match(Name, Value, #qpack_state{dyn_field_index = FieldIndex, dyn_name_index = NameIndex}) ->
    Header = {Name, Value},
    case maps:find(Header, FieldIndex) of
        {ok, AbsIndex} ->
            {exact, AbsIndex};
        error ->
            case maps:find(Name, NameIndex) of
                {ok, AbsIndex} ->
                    {name, AbsIndex};
                error ->
                    none
            end
    end.
