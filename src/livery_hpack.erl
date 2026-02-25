%% @doc HPACK header compression for HTTP/2 (RFC 7541).
%%
%% Optimized for server-side use:
%% - Static table with fast tuple lookup
%% - Dynamic table as queue with O(1) insert/evict
%% - Pre-encoded common response headers
%% - Huffman encoding with lookup tables
-module(livery_hpack).

-export([
    %% Encoder
    encoder_new/0,
    encoder_new/1,
    encode/2,
    encoder_set_max_size/2,
    %% Decoder
    decoder_new/0,
    decoder_new/1,
    decode/2,
    decoder_set_max_size/2
]).

%% Types
-type header() :: {binary(), binary()}.
-type headers() :: [header()].

-record(encoder, {
    dynamic_table :: queue:queue({binary(), binary(), non_neg_integer()}),
    table_size = 0 :: non_neg_integer(),
    max_table_size = 4096 :: non_neg_integer(),
    pending_size_update = false :: boolean()
}).

-record(decoder, {
    dynamic_table :: queue:queue({binary(), binary(), non_neg_integer()}),
    table_size = 0 :: non_neg_integer(),
    max_table_size = 4096 :: non_neg_integer()
}).

-opaque encoder() :: #encoder{}.
-opaque decoder() :: #decoder{}.
-export_type([encoder/0, decoder/0, header/0, headers/0]).

%% @doc Create a new encoder with default max table size (4096).
-spec encoder_new() -> encoder().
encoder_new() ->
    encoder_new(4096).

%% @doc Create a new encoder with specified max table size.
-spec encoder_new(non_neg_integer()) -> encoder().
encoder_new(MaxSize) ->
    #encoder{
        dynamic_table = queue:new(),
        table_size = 0,
        max_table_size = MaxSize
    }.

%% @doc Set max dynamic table size for encoder.
-spec encoder_set_max_size(non_neg_integer(), encoder()) -> encoder().
encoder_set_max_size(MaxSize, Encoder) ->
    Encoder1 = evict_to_size(Encoder, MaxSize),
    Encoder1#encoder{max_table_size = MaxSize, pending_size_update = true}.

%% @doc Encode headers to HPACK binary.
-spec encode(headers(), encoder()) -> {iodata(), encoder()}.
encode(Headers, #encoder{pending_size_update = true, max_table_size = MaxSize} = Encoder) ->
    %% Send size update first
    SizeUpdate = encode_integer(MaxSize, 5, 2#001),
    {Encoded, Encoder1} = encode_headers(Headers, Encoder#encoder{pending_size_update = false}, []),
    {[SizeUpdate | Encoded], Encoder1};
encode(Headers, Encoder) ->
    encode_headers(Headers, Encoder, []).

encode_headers([], Encoder, Acc) ->
    {lists:reverse(Acc), Encoder};
encode_headers([{Name, Value} | Rest], Encoder, Acc) ->
    {Encoded, Encoder1} = encode_header(Name, Value, Encoder),
    encode_headers(Rest, Encoder1, [Encoded | Acc]).

encode_header(Name, Value, Encoder) ->
    LowerName = string:lowercase(Name),
    case static_table_find(LowerName, Value) of
        {exact, Index} ->
            %% Indexed header field (section 6.1)
            {encode_integer(Index, 7, 2#1), Encoder};
        {name, Index} ->
            %% Literal header with indexed name (section 6.2.1)
            encode_literal_indexed_name(Index, Value, Encoder);
        not_found ->
            %% Literal header with literal name (section 6.2.1)
            encode_literal_new_name(LowerName, Value, Encoder)
    end.

encode_literal_indexed_name(Index, Value, Encoder) ->
    %% Literal with indexing, indexed name
    Prefix = encode_integer(Index, 6, 2#01),
    ValueEnc = encode_string(Value),
    %% Add to dynamic table
    Encoder1 = add_to_dynamic_table(get_static_name(Index), Value, Encoder),
    {[Prefix, ValueEnc], Encoder1}.

encode_literal_new_name(Name, Value, Encoder) ->
    %% Literal with indexing, new name
    Prefix = <<2#01000000>>,
    NameEnc = encode_string(Name),
    ValueEnc = encode_string(Value),
    %% Add to dynamic table
    Encoder1 = add_to_dynamic_table(Name, Value, Encoder),
    {[Prefix, NameEnc, ValueEnc], Encoder1}.

%% @doc Create a new decoder with default max table size (4096).
-spec decoder_new() -> decoder().
decoder_new() ->
    decoder_new(4096).

%% @doc Create a new decoder with specified max table size.
-spec decoder_new(non_neg_integer()) -> decoder().
decoder_new(MaxSize) ->
    #decoder{
        dynamic_table = queue:new(),
        table_size = 0,
        max_table_size = MaxSize
    }.

%% @doc Set max dynamic table size for decoder.
-spec decoder_set_max_size(non_neg_integer(), decoder()) -> decoder().
decoder_set_max_size(MaxSize, Decoder) ->
    Decoder1 = evict_decoder_to_size(Decoder, MaxSize),
    Decoder1#decoder{max_table_size = MaxSize}.

%% @doc Decode HPACK binary to headers.
-spec decode(binary(), decoder()) -> {ok, headers(), decoder()} | {error, term()}.
decode(Data, Decoder) ->
    decode_headers(Data, Decoder, []).

decode_headers(<<>>, Decoder, Acc) ->
    {ok, lists:reverse(Acc), Decoder};
decode_headers(<<2#1:1, _/bits>> = Data, Decoder, Acc) ->
    %% Indexed header field (section 6.1)
    case decode_integer(Data, 7) of
        {ok, 0, _} ->
            {error, invalid_index};
        {ok, Index, Rest} ->
            case lookup_table(Index, Decoder) of
                {ok, Name, Value} ->
                    decode_headers(Rest, Decoder, [{Name, Value} | Acc]);
                error ->
                    {error, {invalid_index, Index}}
            end;
        {error, Reason} ->
            {error, Reason}
    end;
decode_headers(<<2#01:2, _/bits>> = Data, Decoder, Acc) ->
    %% Literal with indexing (section 6.2.1)
    case decode_literal_header(Data, 6, true, Decoder) of
        {ok, Name, Value, Rest, Decoder1} ->
            decode_headers(Rest, Decoder1, [{Name, Value} | Acc]);
        {error, Reason} ->
            {error, Reason}
    end;
decode_headers(<<2#0000:4, _/bits>> = Data, Decoder, Acc) ->
    %% Literal without indexing (section 6.2.2)
    case decode_literal_header(Data, 4, false, Decoder) of
        {ok, Name, Value, Rest, Decoder1} ->
            decode_headers(Rest, Decoder1, [{Name, Value} | Acc]);
        {error, Reason} ->
            {error, Reason}
    end;
decode_headers(<<2#0001:4, _/bits>> = Data, Decoder, Acc) ->
    %% Literal never indexed (section 6.2.3)
    case decode_literal_header(Data, 4, false, Decoder) of
        {ok, Name, Value, Rest, Decoder1} ->
            decode_headers(Rest, Decoder1, [{Name, Value} | Acc]);
        {error, Reason} ->
            {error, Reason}
    end;
decode_headers(<<2#001:3, _/bits>> = Data, Decoder, Acc) ->
    %% Dynamic table size update (section 6.3)
    case decode_integer(Data, 5) of
        {ok, NewSize, Rest} ->
            Decoder1 = decoder_set_max_size(NewSize, Decoder),
            decode_headers(Rest, Decoder1, Acc);
        {error, Reason} ->
            {error, Reason}
    end;
decode_headers(<<_/binary>>, _Decoder, _Acc) ->
    {error, invalid_header_block}.

decode_literal_header(Data, PrefixBits, AddToTable, Decoder) ->
    case decode_integer(Data, PrefixBits) of
        {ok, 0, Rest} ->
            %% Literal name
            case decode_string(Rest) of
                {ok, Name, Rest1} ->
                    case decode_string(Rest1) of
                        {ok, Value, Rest2} ->
                            Decoder1 = case AddToTable of
                                true -> add_to_decoder_table(Name, Value, Decoder);
                                false -> Decoder
                            end,
                            {ok, Name, Value, Rest2, Decoder1};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, Index, Rest} ->
            %% Indexed name
            case lookup_table(Index, Decoder) of
                {ok, Name, _} ->
                    case decode_string(Rest) of
                        {ok, Value, Rest1} ->
                            Decoder1 = case AddToTable of
                                true -> add_to_decoder_table(Name, Value, Decoder);
                                false -> Decoder
                            end,
                            {ok, Name, Value, Rest1, Decoder1};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                error ->
                    {error, {invalid_index, Index}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Integer encoding (section 5.1)
%% Encodes an integer with a prefix. PrefixBits is 4, 5, 6, or 7.
%% Prefix is the high bits (already shifted to correct position).
encode_integer(Int, PrefixBits, Prefix) ->
    MaxPrefix = (1 bsl PrefixBits) - 1,
    if
        Int < MaxPrefix ->
            %% Fits in prefix: combine prefix and value
            <<((Prefix bsl PrefixBits) bor Int)>>;
        true ->
            %% Doesn't fit: use max prefix then continuation bytes
            FirstByte = (Prefix bsl PrefixBits) bor MaxPrefix,
            [<<FirstByte>> | encode_integer_rest(Int - MaxPrefix)]
    end.

encode_integer_rest(Int) when Int < 128 ->
    [<<Int:8>>];
encode_integer_rest(Int) ->
    [<<1:1, (Int band 127):7>> | encode_integer_rest(Int bsr 7)].

%% Integer decoding (section 5.1)
%% Extracts an integer from a binary with given prefix bits.
decode_integer(<<Byte, Rest/binary>>, PrefixBits) ->
    MaxPrefix = (1 bsl PrefixBits) - 1,
    Value = Byte band MaxPrefix,
    if
        Value < MaxPrefix ->
            {ok, Value, Rest};
        true ->
            decode_integer_rest(Rest, MaxPrefix, 0)
    end;
decode_integer(<<>>, _PrefixBits) ->
    {error, incomplete_integer}.

decode_integer_rest(<<>>, _Acc, _Shift) ->
    {error, incomplete_integer};
decode_integer_rest(<<0:1, Val:7, Rest/binary>>, Acc, Shift) ->
    {ok, Acc + (Val bsl Shift), Rest};
decode_integer_rest(<<1:1, Val:7, Rest/binary>>, Acc, Shift) ->
    decode_integer_rest(Rest, Acc + (Val bsl Shift), Shift + 7).

%% String encoding (section 5.2)
%% Uses Huffman encoding when it provides smaller output
encode_string(String) when is_binary(String) ->
    LiteralLen = byte_size(String),
    HuffmanEncoded = huffman_encode(String),
    HuffmanLen = byte_size(HuffmanEncoded),

    %% Use Huffman if it's smaller
    case HuffmanLen < LiteralLen of
        true ->
            %% Huffman encoded (H=1)
            if
                HuffmanLen < 127 ->
                    [<<1:1, HuffmanLen:7>>, HuffmanEncoded];
                true ->
                    [<<1:1, 127:7>> | encode_integer_rest(HuffmanLen - 127)] ++ [HuffmanEncoded]
            end;
        false ->
            %% Literal (H=0)
            if
                LiteralLen < 127 ->
                    [<<0:1, LiteralLen:7>>, String];
                true ->
                    [<<0:1, 127:7>> | encode_integer_rest(LiteralLen - 127)] ++ [String]
            end
    end.

%% String decoding (section 5.2)
decode_string(<<1:1, _/bits>> = Data) ->
    %% Huffman encoded
    case decode_integer(Data, 7) of
        {ok, Len, Rest} when byte_size(Rest) >= Len ->
            <<Encoded:Len/binary, Rest1/binary>> = Rest,
            case huffman_decode(Encoded) of
                {ok, Decoded} ->
                    {ok, Decoded, Rest1};
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, _, _} ->
            {error, incomplete_string};
        {error, Reason} ->
            {error, Reason}
    end;
decode_string(<<0:1, _/bits>> = Data) ->
    %% Literal
    case decode_integer(Data, 7) of
        {ok, Len, Rest} when byte_size(Rest) >= Len ->
            <<String:Len/binary, Rest1/binary>> = Rest,
            {ok, String, Rest1};
        {ok, _, _} ->
            {error, incomplete_string};
        {error, Reason} ->
            {error, Reason}
    end.

%% Static table (Appendix A)
static_table_find(Name, Value) ->
    %% Check for exact match first
    case static_table_exact(Name, Value) of
        {exact, Index} -> {exact, Index};
        not_found ->
            %% Check for name-only match
            static_table_name(Name)
    end.

static_table_exact(<<":authority">>, _) -> not_found;
static_table_exact(<<":method">>, <<"GET">>) -> {exact, 2};
static_table_exact(<<":method">>, <<"POST">>) -> {exact, 3};
static_table_exact(<<":path">>, <<"/">>) -> {exact, 4};
static_table_exact(<<":path">>, <<"/index.html">>) -> {exact, 5};
static_table_exact(<<":scheme">>, <<"http">>) -> {exact, 6};
static_table_exact(<<":scheme">>, <<"https">>) -> {exact, 7};
static_table_exact(<<":status">>, <<"200">>) -> {exact, 8};
static_table_exact(<<":status">>, <<"204">>) -> {exact, 9};
static_table_exact(<<":status">>, <<"206">>) -> {exact, 10};
static_table_exact(<<":status">>, <<"304">>) -> {exact, 11};
static_table_exact(<<":status">>, <<"400">>) -> {exact, 12};
static_table_exact(<<":status">>, <<"404">>) -> {exact, 13};
static_table_exact(<<":status">>, <<"500">>) -> {exact, 14};
static_table_exact(_, _) -> not_found.

static_table_name(<<":authority">>) -> {name, 1};
static_table_name(<<":method">>) -> {name, 2};
static_table_name(<<":path">>) -> {name, 4};
static_table_name(<<":scheme">>) -> {name, 6};
static_table_name(<<":status">>) -> {name, 8};
static_table_name(<<"accept-charset">>) -> {name, 15};
static_table_name(<<"accept-encoding">>) -> {name, 16};
static_table_name(<<"accept-language">>) -> {name, 17};
static_table_name(<<"accept-ranges">>) -> {name, 18};
static_table_name(<<"accept">>) -> {name, 19};
static_table_name(<<"access-control-allow-origin">>) -> {name, 20};
static_table_name(<<"age">>) -> {name, 21};
static_table_name(<<"allow">>) -> {name, 22};
static_table_name(<<"authorization">>) -> {name, 23};
static_table_name(<<"cache-control">>) -> {name, 24};
static_table_name(<<"content-disposition">>) -> {name, 25};
static_table_name(<<"content-encoding">>) -> {name, 26};
static_table_name(<<"content-language">>) -> {name, 27};
static_table_name(<<"content-length">>) -> {name, 28};
static_table_name(<<"content-location">>) -> {name, 29};
static_table_name(<<"content-range">>) -> {name, 30};
static_table_name(<<"content-type">>) -> {name, 31};
static_table_name(<<"cookie">>) -> {name, 32};
static_table_name(<<"date">>) -> {name, 33};
static_table_name(<<"etag">>) -> {name, 34};
static_table_name(<<"expect">>) -> {name, 35};
static_table_name(<<"expires">>) -> {name, 36};
static_table_name(<<"from">>) -> {name, 37};
static_table_name(<<"host">>) -> {name, 38};
static_table_name(<<"if-match">>) -> {name, 39};
static_table_name(<<"if-modified-since">>) -> {name, 40};
static_table_name(<<"if-none-match">>) -> {name, 41};
static_table_name(<<"if-range">>) -> {name, 42};
static_table_name(<<"if-unmodified-since">>) -> {name, 43};
static_table_name(<<"last-modified">>) -> {name, 44};
static_table_name(<<"link">>) -> {name, 45};
static_table_name(<<"location">>) -> {name, 46};
static_table_name(<<"max-forwards">>) -> {name, 47};
static_table_name(<<"proxy-authenticate">>) -> {name, 48};
static_table_name(<<"proxy-authorization">>) -> {name, 49};
static_table_name(<<"range">>) -> {name, 50};
static_table_name(<<"referer">>) -> {name, 51};
static_table_name(<<"refresh">>) -> {name, 52};
static_table_name(<<"retry-after">>) -> {name, 53};
static_table_name(<<"server">>) -> {name, 54};
static_table_name(<<"set-cookie">>) -> {name, 55};
static_table_name(<<"strict-transport-security">>) -> {name, 56};
static_table_name(<<"transfer-encoding">>) -> {name, 57};
static_table_name(<<"user-agent">>) -> {name, 58};
static_table_name(<<"vary">>) -> {name, 59};
static_table_name(<<"via">>) -> {name, 60};
static_table_name(<<"www-authenticate">>) -> {name, 61};
static_table_name(_) -> not_found.

get_static_name(1) -> <<":authority">>;
get_static_name(2) -> <<":method">>;
get_static_name(3) -> <<":method">>;
get_static_name(4) -> <<":path">>;
get_static_name(5) -> <<":path">>;
get_static_name(6) -> <<":scheme">>;
get_static_name(7) -> <<":scheme">>;
get_static_name(8) -> <<":status">>;
get_static_name(9) -> <<":status">>;
get_static_name(10) -> <<":status">>;
get_static_name(11) -> <<":status">>;
get_static_name(12) -> <<":status">>;
get_static_name(13) -> <<":status">>;
get_static_name(14) -> <<":status">>;
get_static_name(15) -> <<"accept-charset">>;
get_static_name(16) -> <<"accept-encoding">>;
get_static_name(17) -> <<"accept-language">>;
get_static_name(18) -> <<"accept-ranges">>;
get_static_name(19) -> <<"accept">>;
get_static_name(20) -> <<"access-control-allow-origin">>;
get_static_name(21) -> <<"age">>;
get_static_name(22) -> <<"allow">>;
get_static_name(23) -> <<"authorization">>;
get_static_name(24) -> <<"cache-control">>;
get_static_name(25) -> <<"content-disposition">>;
get_static_name(26) -> <<"content-encoding">>;
get_static_name(27) -> <<"content-language">>;
get_static_name(28) -> <<"content-length">>;
get_static_name(29) -> <<"content-location">>;
get_static_name(30) -> <<"content-range">>;
get_static_name(31) -> <<"content-type">>;
get_static_name(32) -> <<"cookie">>;
get_static_name(33) -> <<"date">>;
get_static_name(34) -> <<"etag">>;
get_static_name(35) -> <<"expect">>;
get_static_name(36) -> <<"expires">>;
get_static_name(37) -> <<"from">>;
get_static_name(38) -> <<"host">>;
get_static_name(39) -> <<"if-match">>;
get_static_name(40) -> <<"if-modified-since">>;
get_static_name(41) -> <<"if-none-match">>;
get_static_name(42) -> <<"if-range">>;
get_static_name(43) -> <<"if-unmodified-since">>;
get_static_name(44) -> <<"last-modified">>;
get_static_name(45) -> <<"link">>;
get_static_name(46) -> <<"location">>;
get_static_name(47) -> <<"max-forwards">>;
get_static_name(48) -> <<"proxy-authenticate">>;
get_static_name(49) -> <<"proxy-authorization">>;
get_static_name(50) -> <<"range">>;
get_static_name(51) -> <<"referer">>;
get_static_name(52) -> <<"refresh">>;
get_static_name(53) -> <<"retry-after">>;
get_static_name(54) -> <<"server">>;
get_static_name(55) -> <<"set-cookie">>;
get_static_name(56) -> <<"strict-transport-security">>;
get_static_name(57) -> <<"transfer-encoding">>;
get_static_name(58) -> <<"user-agent">>;
get_static_name(59) -> <<"vary">>;
get_static_name(60) -> <<"via">>;
get_static_name(61) -> <<"www-authenticate">>;
get_static_name(_) -> undefined.

get_static_entry(1) -> {<<":authority">>, <<>>};
get_static_entry(2) -> {<<":method">>, <<"GET">>};
get_static_entry(3) -> {<<":method">>, <<"POST">>};
get_static_entry(4) -> {<<":path">>, <<"/">>};
get_static_entry(5) -> {<<":path">>, <<"/index.html">>};
get_static_entry(6) -> {<<":scheme">>, <<"http">>};
get_static_entry(7) -> {<<":scheme">>, <<"https">>};
get_static_entry(8) -> {<<":status">>, <<"200">>};
get_static_entry(9) -> {<<":status">>, <<"204">>};
get_static_entry(10) -> {<<":status">>, <<"206">>};
get_static_entry(11) -> {<<":status">>, <<"304">>};
get_static_entry(12) -> {<<":status">>, <<"400">>};
get_static_entry(13) -> {<<":status">>, <<"404">>};
get_static_entry(14) -> {<<":status">>, <<"500">>};
get_static_entry(15) -> {<<"accept-charset">>, <<>>};
get_static_entry(16) -> {<<"accept-encoding">>, <<"gzip, deflate">>};
get_static_entry(17) -> {<<"accept-language">>, <<>>};
get_static_entry(18) -> {<<"accept-ranges">>, <<>>};
get_static_entry(19) -> {<<"accept">>, <<>>};
get_static_entry(20) -> {<<"access-control-allow-origin">>, <<>>};
get_static_entry(21) -> {<<"age">>, <<>>};
get_static_entry(22) -> {<<"allow">>, <<>>};
get_static_entry(23) -> {<<"authorization">>, <<>>};
get_static_entry(24) -> {<<"cache-control">>, <<>>};
get_static_entry(25) -> {<<"content-disposition">>, <<>>};
get_static_entry(26) -> {<<"content-encoding">>, <<>>};
get_static_entry(27) -> {<<"content-language">>, <<>>};
get_static_entry(28) -> {<<"content-length">>, <<>>};
get_static_entry(29) -> {<<"content-location">>, <<>>};
get_static_entry(30) -> {<<"content-range">>, <<>>};
get_static_entry(31) -> {<<"content-type">>, <<>>};
get_static_entry(32) -> {<<"cookie">>, <<>>};
get_static_entry(33) -> {<<"date">>, <<>>};
get_static_entry(34) -> {<<"etag">>, <<>>};
get_static_entry(35) -> {<<"expect">>, <<>>};
get_static_entry(36) -> {<<"expires">>, <<>>};
get_static_entry(37) -> {<<"from">>, <<>>};
get_static_entry(38) -> {<<"host">>, <<>>};
get_static_entry(39) -> {<<"if-match">>, <<>>};
get_static_entry(40) -> {<<"if-modified-since">>, <<>>};
get_static_entry(41) -> {<<"if-none-match">>, <<>>};
get_static_entry(42) -> {<<"if-range">>, <<>>};
get_static_entry(43) -> {<<"if-unmodified-since">>, <<>>};
get_static_entry(44) -> {<<"last-modified">>, <<>>};
get_static_entry(45) -> {<<"link">>, <<>>};
get_static_entry(46) -> {<<"location">>, <<>>};
get_static_entry(47) -> {<<"max-forwards">>, <<>>};
get_static_entry(48) -> {<<"proxy-authenticate">>, <<>>};
get_static_entry(49) -> {<<"proxy-authorization">>, <<>>};
get_static_entry(50) -> {<<"range">>, <<>>};
get_static_entry(51) -> {<<"referer">>, <<>>};
get_static_entry(52) -> {<<"refresh">>, <<>>};
get_static_entry(53) -> {<<"retry-after">>, <<>>};
get_static_entry(54) -> {<<"server">>, <<>>};
get_static_entry(55) -> {<<"set-cookie">>, <<>>};
get_static_entry(56) -> {<<"strict-transport-security">>, <<>>};
get_static_entry(57) -> {<<"transfer-encoding">>, <<>>};
get_static_entry(58) -> {<<"user-agent">>, <<>>};
get_static_entry(59) -> {<<"vary">>, <<>>};
get_static_entry(60) -> {<<"via">>, <<>>};
get_static_entry(61) -> {<<"www-authenticate">>, <<>>};
get_static_entry(_) -> undefined.

%% Dynamic table operations for encoder
add_to_dynamic_table(Name, Value, #encoder{max_table_size = MaxSize} = Encoder) ->
    EntrySize = byte_size(Name) + byte_size(Value) + 32,
    %% First evict if necessary
    Encoder1 = evict_to_fit(Encoder, EntrySize),
    %% Only add if entry fits
    if
        EntrySize =< MaxSize ->
            NewTable = queue:in({Name, Value, EntrySize}, Encoder1#encoder.dynamic_table),
            Encoder1#encoder{dynamic_table = NewTable,
                            table_size = Encoder1#encoder.table_size + EntrySize};
        true ->
            Encoder1
    end.

evict_to_fit(#encoder{max_table_size = MaxSize} = Encoder, EntrySize) ->
    evict_to_size(Encoder, MaxSize - EntrySize).

evict_to_size(Encoder, TargetSize) when TargetSize < 0 ->
    %% Clear entire table
    Encoder#encoder{dynamic_table = queue:new(), table_size = 0};
evict_to_size(#encoder{table_size = Size} = Encoder, TargetSize) when Size =< TargetSize ->
    Encoder;
evict_to_size(#encoder{dynamic_table = Table, table_size = Size} = Encoder, TargetSize) ->
    case queue:out(Table) of
        {{value, {_, _, EntrySize}}, NewTable} ->
            evict_to_size(Encoder#encoder{dynamic_table = NewTable,
                                          table_size = Size - EntrySize}, TargetSize);
        {empty, _} ->
            Encoder#encoder{table_size = 0}
    end.

%% Dynamic table operations for decoder
add_to_decoder_table(Name, Value, #decoder{max_table_size = MaxSize} = Decoder) ->
    EntrySize = byte_size(Name) + byte_size(Value) + 32,
    %% First evict if necessary
    Decoder1 = evict_decoder_to_fit(Decoder, EntrySize),
    %% Only add if entry fits
    if
        EntrySize =< MaxSize ->
            NewTable = queue:in({Name, Value, EntrySize}, Decoder1#decoder.dynamic_table),
            Decoder1#decoder{dynamic_table = NewTable,
                            table_size = Decoder1#decoder.table_size + EntrySize};
        true ->
            Decoder1
    end.

evict_decoder_to_fit(#decoder{max_table_size = MaxSize} = Decoder, EntrySize) ->
    evict_decoder_to_size(Decoder, MaxSize - EntrySize).

evict_decoder_to_size(Decoder, TargetSize) when TargetSize < 0 ->
    Decoder#decoder{dynamic_table = queue:new(), table_size = 0};
evict_decoder_to_size(#decoder{table_size = Size} = Decoder, TargetSize) when Size =< TargetSize ->
    Decoder;
evict_decoder_to_size(#decoder{dynamic_table = Table, table_size = Size} = Decoder, TargetSize) ->
    case queue:out(Table) of
        {{value, {_, _, EntrySize}}, NewTable} ->
            evict_decoder_to_size(Decoder#decoder{dynamic_table = NewTable,
                                                   table_size = Size - EntrySize}, TargetSize);
        {empty, _} ->
            Decoder#decoder{table_size = 0}
    end.

%% Table lookup
lookup_table(Index, _) when Index =< 61 ->
    case get_static_entry(Index) of
        undefined -> error;
        {Name, Value} -> {ok, Name, Value}
    end;
lookup_table(Index, #decoder{dynamic_table = Table}) ->
    DynIndex = Index - 61,
    lookup_dynamic(Table, DynIndex).

lookup_dynamic(Table, Index) ->
    %% Dynamic table is FIFO but indexed from newest to oldest
    %% So we need to reverse-index
    List = queue:to_list(Table),
    Len = length(List),
    ReverseIndex = Len - Index + 1,
    case ReverseIndex >= 1 andalso ReverseIndex =< Len of
        true ->
            {Name, Value, _} = lists:nth(ReverseIndex, List),
            {ok, Name, Value};
        false ->
            error
    end.

%% Huffman decoding (simplified - uses lookup table)
huffman_decode(Data) ->
    huffman_decode(Data, <<>>, 0, 0).

huffman_decode(<<>>, Acc, _, _) ->
    {ok, Acc};
huffman_decode(<<Byte, Rest/binary>>, Acc, Bits, Code) ->
    %% Process byte bit by bit
    huffman_decode_bits(<<Byte>>, 8, Rest, Acc, Bits, Code).

huffman_decode_bits(_, 0, Rest, Acc, Bits, Code) ->
    huffman_decode(Rest, Acc, Bits, Code);
huffman_decode_bits(<<Byte, _/binary>> = Data, BitsLeft, Rest, Acc, Bits, Code) when BitsLeft > 0 ->
    Bit = (Byte bsr (BitsLeft - 1)) band 1,
    NewCode = (Code bsl 1) bor Bit,
    NewBits = Bits + 1,
    case huffman_lookup(NewCode, NewBits) of
        {ok, Char} ->
            huffman_decode_bits(Data, BitsLeft - 1, Rest, <<Acc/binary, Char>>, 0, 0);
        continue ->
            huffman_decode_bits(Data, BitsLeft - 1, Rest, Acc, NewBits, NewCode);
        eos ->
            %% End of string padding
            {ok, Acc};
        error ->
            {error, invalid_huffman}
    end.

%% Huffman decode lookup table (RFC 7541 Appendix B)
%% This is the inverse of huffman_code - given (Code, CodeLength), return byte value
%% 5-bit codes
huffman_lookup(16#0, 5) -> {ok, 48};        %% '0'
huffman_lookup(16#1, 5) -> {ok, 49};        %% '1'
huffman_lookup(16#2, 5) -> {ok, 50};        %% '2'
huffman_lookup(16#3, 5) -> {ok, 97};        %% 'a'
huffman_lookup(16#4, 5) -> {ok, 99};        %% 'c'
huffman_lookup(16#5, 5) -> {ok, 101};       %% 'e'
huffman_lookup(16#6, 5) -> {ok, 105};       %% 'i'
huffman_lookup(16#7, 5) -> {ok, 111};       %% 'o'
huffman_lookup(16#8, 5) -> {ok, 115};       %% 's'
huffman_lookup(16#9, 5) -> {ok, 116};       %% 't'
%% 6-bit codes
huffman_lookup(16#14, 6) -> {ok, 32};       %% ' '
huffman_lookup(16#15, 6) -> {ok, 37};       %% '%'
huffman_lookup(16#16, 6) -> {ok, 45};       %% '-'
huffman_lookup(16#17, 6) -> {ok, 46};       %% '.'
huffman_lookup(16#18, 6) -> {ok, 47};       %% '/'
huffman_lookup(16#19, 6) -> {ok, 51};       %% '3'
huffman_lookup(16#1a, 6) -> {ok, 52};       %% '4'
huffman_lookup(16#1b, 6) -> {ok, 53};       %% '5'
huffman_lookup(16#1c, 6) -> {ok, 54};       %% '6'
huffman_lookup(16#1d, 6) -> {ok, 55};       %% '7'
huffman_lookup(16#1e, 6) -> {ok, 56};       %% '8'
huffman_lookup(16#1f, 6) -> {ok, 57};       %% '9'
huffman_lookup(16#20, 6) -> {ok, 61};       %% '='
huffman_lookup(16#21, 6) -> {ok, 65};       %% 'A'
huffman_lookup(16#22, 6) -> {ok, 95};       %% '_'
huffman_lookup(16#23, 6) -> {ok, 98};       %% 'b'
huffman_lookup(16#24, 6) -> {ok, 100};      %% 'd'
huffman_lookup(16#25, 6) -> {ok, 102};      %% 'f'
huffman_lookup(16#26, 6) -> {ok, 103};      %% 'g'
huffman_lookup(16#27, 6) -> {ok, 104};      %% 'h'
huffman_lookup(16#28, 6) -> {ok, 108};      %% 'l'
huffman_lookup(16#29, 6) -> {ok, 109};      %% 'm'
huffman_lookup(16#2a, 6) -> {ok, 110};      %% 'n'
huffman_lookup(16#2b, 6) -> {ok, 112};      %% 'p'
huffman_lookup(16#2c, 6) -> {ok, 114};      %% 'r'
huffman_lookup(16#2d, 6) -> {ok, 117};      %% 'u'
%% 7-bit codes
huffman_lookup(16#5c, 7) -> {ok, 58};       %% ':'
huffman_lookup(16#5d, 7) -> {ok, 66};       %% 'B'
huffman_lookup(16#5e, 7) -> {ok, 67};       %% 'C'
huffman_lookup(16#5f, 7) -> {ok, 68};       %% 'D'
huffman_lookup(16#60, 7) -> {ok, 69};       %% 'E'
huffman_lookup(16#61, 7) -> {ok, 70};       %% 'F'
huffman_lookup(16#62, 7) -> {ok, 71};       %% 'G'
huffman_lookup(16#63, 7) -> {ok, 72};       %% 'H'
huffman_lookup(16#64, 7) -> {ok, 73};       %% 'I'
huffman_lookup(16#65, 7) -> {ok, 74};       %% 'J'
huffman_lookup(16#66, 7) -> {ok, 75};       %% 'K'
huffman_lookup(16#67, 7) -> {ok, 76};       %% 'L'
huffman_lookup(16#68, 7) -> {ok, 77};       %% 'M'
huffman_lookup(16#69, 7) -> {ok, 78};       %% 'N'
huffman_lookup(16#6a, 7) -> {ok, 79};       %% 'O'
huffman_lookup(16#6b, 7) -> {ok, 80};       %% 'P'
huffman_lookup(16#6c, 7) -> {ok, 81};       %% 'Q'
huffman_lookup(16#6d, 7) -> {ok, 82};       %% 'R'
huffman_lookup(16#6e, 7) -> {ok, 83};       %% 'S'
huffman_lookup(16#6f, 7) -> {ok, 84};       %% 'T'
huffman_lookup(16#70, 7) -> {ok, 85};       %% 'U'
huffman_lookup(16#71, 7) -> {ok, 86};       %% 'V'
huffman_lookup(16#72, 7) -> {ok, 87};       %% 'W'
huffman_lookup(16#73, 7) -> {ok, 89};       %% 'Y'
huffman_lookup(16#74, 7) -> {ok, 106};      %% 'j'
huffman_lookup(16#75, 7) -> {ok, 107};      %% 'k'
huffman_lookup(16#76, 7) -> {ok, 113};      %% 'q'
huffman_lookup(16#77, 7) -> {ok, 118};      %% 'v'
huffman_lookup(16#78, 7) -> {ok, 119};      %% 'w'
huffman_lookup(16#79, 7) -> {ok, 120};      %% 'x'
huffman_lookup(16#7a, 7) -> {ok, 121};      %% 'y'
huffman_lookup(16#7b, 7) -> {ok, 122};      %% 'z'
%% 8-bit codes
huffman_lookup(16#f8, 8) -> {ok, 38};       %% '&'
huffman_lookup(16#f9, 8) -> {ok, 42};       %% '*'
huffman_lookup(16#fa, 8) -> {ok, 44};       %% ','
huffman_lookup(16#fb, 8) -> {ok, 59};       %% ';'
huffman_lookup(16#fc, 8) -> {ok, 88};       %% 'X'
huffman_lookup(16#fd, 8) -> {ok, 90};       %% 'Z'
%% 10-bit codes
huffman_lookup(16#3f8, 10) -> {ok, 33};     %% '!'
huffman_lookup(16#3f9, 10) -> {ok, 34};     %% '"'
huffman_lookup(16#3fa, 10) -> {ok, 40};     %% '('
huffman_lookup(16#3fb, 10) -> {ok, 41};     %% ')'
huffman_lookup(16#3fc, 10) -> {ok, 63};     %% '?'
%% 11-bit codes
huffman_lookup(16#7fa, 11) -> {ok, 39};     %% '''
huffman_lookup(16#7fb, 11) -> {ok, 43};     %% '+'
huffman_lookup(16#7fc, 11) -> {ok, 124};    %% '|'
%% 12-bit codes
huffman_lookup(16#ffa, 12) -> {ok, 35};     %% '#'
huffman_lookup(16#ffb, 12) -> {ok, 62};     %% '>'
%% 13-bit codes
huffman_lookup(16#1ff8, 13) -> {ok, 0};
huffman_lookup(16#1ff9, 13) -> {ok, 36};    %% '$'
huffman_lookup(16#1ffa, 13) -> {ok, 64};    %% '@'
huffman_lookup(16#1ffb, 13) -> {ok, 91};    %% '['
huffman_lookup(16#1ffc, 13) -> {ok, 93};    %% ']'
huffman_lookup(16#1ffd, 13) -> {ok, 126};   %% '~'
%% 14-bit codes
huffman_lookup(16#3ffc, 14) -> {ok, 94};    %% '^'
huffman_lookup(16#3ffd, 14) -> {ok, 125};   %% '}'
%% 15-bit codes
huffman_lookup(16#7ffc, 15) -> {ok, 60};    %% '<'
huffman_lookup(16#7ffd, 15) -> {ok, 96};    %% '`'
huffman_lookup(16#7ffe, 15) -> {ok, 123};   %% '{'
%% 19-bit codes
huffman_lookup(16#7fff0, 19) -> {ok, 92};   %% '\'
huffman_lookup(16#7fff1, 19) -> {ok, 195};
huffman_lookup(16#7fff2, 19) -> {ok, 208};
%% 20-bit codes
huffman_lookup(16#fffe6, 20) -> {ok, 128};
huffman_lookup(16#fffe7, 20) -> {ok, 130};
huffman_lookup(16#fffe8, 20) -> {ok, 131};
huffman_lookup(16#fffe9, 20) -> {ok, 162};
huffman_lookup(16#fffea, 20) -> {ok, 184};
huffman_lookup(16#fffeb, 20) -> {ok, 194};
huffman_lookup(16#fffec, 20) -> {ok, 224};
huffman_lookup(16#fffed, 20) -> {ok, 226};
%% 21-bit codes
huffman_lookup(16#1fffdc, 21) -> {ok, 153};
huffman_lookup(16#1fffdd, 21) -> {ok, 161};
huffman_lookup(16#1fffde, 21) -> {ok, 167};
huffman_lookup(16#1fffdf, 21) -> {ok, 172};
huffman_lookup(16#1fffe0, 21) -> {ok, 176};
huffman_lookup(16#1fffe1, 21) -> {ok, 177};
huffman_lookup(16#1fffe2, 21) -> {ok, 179};
huffman_lookup(16#1fffe3, 21) -> {ok, 209};
huffman_lookup(16#1fffe4, 21) -> {ok, 216};
huffman_lookup(16#1fffe5, 21) -> {ok, 217};
huffman_lookup(16#1fffe6, 21) -> {ok, 227};
huffman_lookup(16#1fffe7, 21) -> {ok, 229};
huffman_lookup(16#1fffe8, 21) -> {ok, 230};
%% 22-bit codes
huffman_lookup(16#3fffd2, 22) -> {ok, 129};
huffman_lookup(16#3fffd3, 22) -> {ok, 132};
huffman_lookup(16#3fffd4, 22) -> {ok, 133};
huffman_lookup(16#3fffd5, 22) -> {ok, 134};
huffman_lookup(16#3fffd6, 22) -> {ok, 136};
huffman_lookup(16#3fffd7, 22) -> {ok, 146};
huffman_lookup(16#3fffd8, 22) -> {ok, 154};
huffman_lookup(16#3fffd9, 22) -> {ok, 156};
huffman_lookup(16#3fffda, 22) -> {ok, 160};
huffman_lookup(16#3fffdb, 22) -> {ok, 163};
huffman_lookup(16#3fffdc, 22) -> {ok, 164};
huffman_lookup(16#3fffdd, 22) -> {ok, 169};
huffman_lookup(16#3fffde, 22) -> {ok, 170};
huffman_lookup(16#3fffdf, 22) -> {ok, 173};
huffman_lookup(16#3fffe0, 22) -> {ok, 178};
huffman_lookup(16#3fffe1, 22) -> {ok, 181};
huffman_lookup(16#3fffe2, 22) -> {ok, 185};
huffman_lookup(16#3fffe3, 22) -> {ok, 186};
huffman_lookup(16#3fffe4, 22) -> {ok, 187};
huffman_lookup(16#3fffe5, 22) -> {ok, 189};
huffman_lookup(16#3fffe6, 22) -> {ok, 190};
huffman_lookup(16#3fffe7, 22) -> {ok, 196};
huffman_lookup(16#3fffe8, 22) -> {ok, 198};
huffman_lookup(16#3fffe9, 22) -> {ok, 228};
huffman_lookup(16#3fffea, 22) -> {ok, 232};
huffman_lookup(16#3fffeb, 22) -> {ok, 233};
%% 23-bit codes
huffman_lookup(16#7fffd8, 23) -> {ok, 1};
huffman_lookup(16#7fffd9, 23) -> {ok, 135};
huffman_lookup(16#7fffda, 23) -> {ok, 137};
huffman_lookup(16#7fffdb, 23) -> {ok, 138};
huffman_lookup(16#7fffdc, 23) -> {ok, 139};
huffman_lookup(16#7fffdd, 23) -> {ok, 140};
huffman_lookup(16#7fffde, 23) -> {ok, 141};
huffman_lookup(16#7fffdf, 23) -> {ok, 143};
huffman_lookup(16#7fffe0, 23) -> {ok, 147};
huffman_lookup(16#7fffe1, 23) -> {ok, 149};
huffman_lookup(16#7fffe2, 23) -> {ok, 150};
huffman_lookup(16#7fffe3, 23) -> {ok, 151};
huffman_lookup(16#7fffe4, 23) -> {ok, 152};
huffman_lookup(16#7fffe5, 23) -> {ok, 155};
huffman_lookup(16#7fffe6, 23) -> {ok, 157};
huffman_lookup(16#7fffe7, 23) -> {ok, 158};
huffman_lookup(16#7fffe8, 23) -> {ok, 165};
huffman_lookup(16#7fffe9, 23) -> {ok, 166};
huffman_lookup(16#7fffea, 23) -> {ok, 168};
huffman_lookup(16#7fffeb, 23) -> {ok, 174};
huffman_lookup(16#7fffec, 23) -> {ok, 175};
huffman_lookup(16#7fffed, 23) -> {ok, 180};
huffman_lookup(16#7fffee, 23) -> {ok, 182};
huffman_lookup(16#7fffef, 23) -> {ok, 183};
huffman_lookup(16#7ffff0, 23) -> {ok, 188};
huffman_lookup(16#7ffff1, 23) -> {ok, 191};
huffman_lookup(16#7ffff2, 23) -> {ok, 197};
huffman_lookup(16#7ffff3, 23) -> {ok, 231};
huffman_lookup(16#7ffff4, 23) -> {ok, 239};
%% 24-bit codes
huffman_lookup(16#ffffea, 24) -> {ok, 9};
huffman_lookup(16#ffffeb, 24) -> {ok, 142};
huffman_lookup(16#ffffec, 24) -> {ok, 144};
huffman_lookup(16#ffffed, 24) -> {ok, 145};
huffman_lookup(16#ffffee, 24) -> {ok, 148};
huffman_lookup(16#ffffef, 24) -> {ok, 159};
huffman_lookup(16#fffff0, 24) -> {ok, 171};
huffman_lookup(16#fffff1, 24) -> {ok, 206};
huffman_lookup(16#fffff2, 24) -> {ok, 215};
huffman_lookup(16#fffff3, 24) -> {ok, 225};
huffman_lookup(16#fffff4, 24) -> {ok, 236};
huffman_lookup(16#fffff5, 24) -> {ok, 237};
%% 25-bit codes
huffman_lookup(16#1ffffec, 25) -> {ok, 199};
huffman_lookup(16#1ffffed, 25) -> {ok, 207};
huffman_lookup(16#1ffffee, 25) -> {ok, 234};
huffman_lookup(16#1ffffef, 25) -> {ok, 235};
%% 26-bit codes
huffman_lookup(16#3ffffe0, 26) -> {ok, 192};
huffman_lookup(16#3ffffe1, 26) -> {ok, 193};
huffman_lookup(16#3ffffe2, 26) -> {ok, 200};
huffman_lookup(16#3ffffe3, 26) -> {ok, 201};
huffman_lookup(16#3ffffe4, 26) -> {ok, 202};
huffman_lookup(16#3ffffe5, 26) -> {ok, 205};
huffman_lookup(16#3ffffe6, 26) -> {ok, 210};
huffman_lookup(16#3ffffe7, 26) -> {ok, 213};
huffman_lookup(16#3ffffe8, 26) -> {ok, 218};
huffman_lookup(16#3ffffe9, 26) -> {ok, 219};
huffman_lookup(16#3ffffea, 26) -> {ok, 238};
huffman_lookup(16#3ffffeb, 26) -> {ok, 240};
huffman_lookup(16#3ffffec, 26) -> {ok, 242};
huffman_lookup(16#3ffffed, 26) -> {ok, 243};
huffman_lookup(16#3ffffee, 26) -> {ok, 255};
%% 27-bit codes
huffman_lookup(16#7ffffde, 27) -> {ok, 203};
huffman_lookup(16#7ffffdf, 27) -> {ok, 204};
huffman_lookup(16#7ffffe0, 27) -> {ok, 211};
huffman_lookup(16#7ffffe1, 27) -> {ok, 212};
huffman_lookup(16#7ffffe2, 27) -> {ok, 214};
huffman_lookup(16#7ffffe3, 27) -> {ok, 221};
huffman_lookup(16#7ffffe4, 27) -> {ok, 222};
huffman_lookup(16#7ffffe5, 27) -> {ok, 223};
huffman_lookup(16#7ffffe6, 27) -> {ok, 241};
huffman_lookup(16#7ffffe7, 27) -> {ok, 244};
huffman_lookup(16#7ffffe8, 27) -> {ok, 245};
huffman_lookup(16#7ffffe9, 27) -> {ok, 246};
huffman_lookup(16#7ffffea, 27) -> {ok, 247};
huffman_lookup(16#7ffffeb, 27) -> {ok, 248};
huffman_lookup(16#7ffffec, 27) -> {ok, 250};
huffman_lookup(16#7ffffed, 27) -> {ok, 251};
huffman_lookup(16#7ffffee, 27) -> {ok, 252};
huffman_lookup(16#7ffffef, 27) -> {ok, 253};
huffman_lookup(16#7fffff0, 27) -> {ok, 254};
%% 28-bit codes
huffman_lookup(16#fffffe2, 28) -> {ok, 2};
huffman_lookup(16#fffffe3, 28) -> {ok, 3};
huffman_lookup(16#fffffe4, 28) -> {ok, 4};
huffman_lookup(16#fffffe5, 28) -> {ok, 5};
huffman_lookup(16#fffffe6, 28) -> {ok, 6};
huffman_lookup(16#fffffe7, 28) -> {ok, 7};
huffman_lookup(16#fffffe8, 28) -> {ok, 8};
huffman_lookup(16#fffffe9, 28) -> {ok, 11};
huffman_lookup(16#fffffea, 28) -> {ok, 12};
huffman_lookup(16#fffffeb, 28) -> {ok, 14};
huffman_lookup(16#fffffec, 28) -> {ok, 15};
huffman_lookup(16#fffffed, 28) -> {ok, 16};
huffman_lookup(16#fffffee, 28) -> {ok, 17};
huffman_lookup(16#fffffef, 28) -> {ok, 18};
huffman_lookup(16#ffffff0, 28) -> {ok, 19};
huffman_lookup(16#ffffff1, 28) -> {ok, 20};
huffman_lookup(16#ffffff2, 28) -> {ok, 21};
huffman_lookup(16#ffffff3, 28) -> {ok, 23};
huffman_lookup(16#ffffff4, 28) -> {ok, 24};
huffman_lookup(16#ffffff5, 28) -> {ok, 25};
huffman_lookup(16#ffffff6, 28) -> {ok, 26};
huffman_lookup(16#ffffff7, 28) -> {ok, 27};
huffman_lookup(16#ffffff8, 28) -> {ok, 28};
huffman_lookup(16#ffffff9, 28) -> {ok, 29};
huffman_lookup(16#ffffffa, 28) -> {ok, 30};
huffman_lookup(16#ffffffb, 28) -> {ok, 31};
huffman_lookup(16#ffffffc, 28) -> {ok, 127};
huffman_lookup(16#ffffffd, 28) -> {ok, 220};
huffman_lookup(16#ffffffe, 28) -> {ok, 249};
%% 30-bit codes
huffman_lookup(16#3ffffffc, 30) -> {ok, 10};
huffman_lookup(16#3ffffffd, 30) -> {ok, 13};
huffman_lookup(16#3ffffffe, 30) -> {ok, 22};
huffman_lookup(16#3fffffff, 30) -> eos;     %% EOS (End of string)
%% Catch-all
huffman_lookup(_Code, Bits) when Bits >= 30 -> error;
huffman_lookup(_, _) -> continue.

%% Huffman encoding (RFC 7541 Appendix B)
huffman_encode(Binary) ->
    huffman_encode(Binary, 0, 0).

huffman_encode(<<>>, Bits, Acc) ->
    %% Pad with EOS prefix bits (all 1s)
    case Bits rem 8 of
        0 -> <<Acc:Bits>>;
        Rem ->
            PadBits = 8 - Rem,
            Padding = (1 bsl PadBits) - 1,  %% All 1s
            <<(Acc bsl PadBits bor Padding):(Bits + PadBits)>>
    end;
huffman_encode(<<Byte, Rest/binary>>, Bits, Acc) ->
    {Code, CodeLen} = huffman_code(Byte),
    huffman_encode(Rest, Bits + CodeLen, (Acc bsl CodeLen) bor Code).

%% Huffman code table (RFC 7541 Appendix B)
%% Returns {Code, CodeLength} for each byte value
huffman_code(0) -> {16#1ff8, 13};
huffman_code(1) -> {16#7fffd8, 23};
huffman_code(2) -> {16#fffffe2, 28};
huffman_code(3) -> {16#fffffe3, 28};
huffman_code(4) -> {16#fffffe4, 28};
huffman_code(5) -> {16#fffffe5, 28};
huffman_code(6) -> {16#fffffe6, 28};
huffman_code(7) -> {16#fffffe7, 28};
huffman_code(8) -> {16#fffffe8, 28};
huffman_code(9) -> {16#ffffea, 24};
huffman_code(10) -> {16#3ffffffc, 30};
huffman_code(11) -> {16#fffffe9, 28};
huffman_code(12) -> {16#fffffea, 28};
huffman_code(13) -> {16#3ffffffd, 30};
huffman_code(14) -> {16#fffffeb, 28};
huffman_code(15) -> {16#fffffec, 28};
huffman_code(16) -> {16#fffffed, 28};
huffman_code(17) -> {16#fffffee, 28};
huffman_code(18) -> {16#fffffef, 28};
huffman_code(19) -> {16#ffffff0, 28};
huffman_code(20) -> {16#ffffff1, 28};
huffman_code(21) -> {16#ffffff2, 28};
huffman_code(22) -> {16#3ffffffe, 30};
huffman_code(23) -> {16#ffffff3, 28};
huffman_code(24) -> {16#ffffff4, 28};
huffman_code(25) -> {16#ffffff5, 28};
huffman_code(26) -> {16#ffffff6, 28};
huffman_code(27) -> {16#ffffff7, 28};
huffman_code(28) -> {16#ffffff8, 28};
huffman_code(29) -> {16#ffffff9, 28};
huffman_code(30) -> {16#ffffffa, 28};
huffman_code(31) -> {16#ffffffb, 28};
huffman_code(32) -> {16#14, 6};       %% ' '
huffman_code(33) -> {16#3f8, 10};     %% '!'
huffman_code(34) -> {16#3f9, 10};     %% '"'
huffman_code(35) -> {16#ffa, 12};     %% '#'
huffman_code(36) -> {16#1ff9, 13};    %% '$'
huffman_code(37) -> {16#15, 6};       %% '%'
huffman_code(38) -> {16#f8, 8};       %% '&'
huffman_code(39) -> {16#7fa, 11};     %% '''
huffman_code(40) -> {16#3fa, 10};     %% '('
huffman_code(41) -> {16#3fb, 10};     %% ')'
huffman_code(42) -> {16#f9, 8};       %% '*'
huffman_code(43) -> {16#7fb, 11};     %% '+'
huffman_code(44) -> {16#fa, 8};       %% ','
huffman_code(45) -> {16#16, 6};       %% '-'
huffman_code(46) -> {16#17, 6};       %% '.'
huffman_code(47) -> {16#18, 6};       %% '/'
huffman_code(48) -> {16#0, 5};        %% '0'
huffman_code(49) -> {16#1, 5};        %% '1'
huffman_code(50) -> {16#2, 5};        %% '2'
huffman_code(51) -> {16#19, 6};       %% '3'
huffman_code(52) -> {16#1a, 6};       %% '4'
huffman_code(53) -> {16#1b, 6};       %% '5'
huffman_code(54) -> {16#1c, 6};       %% '6'
huffman_code(55) -> {16#1d, 6};       %% '7'
huffman_code(56) -> {16#1e, 6};       %% '8'
huffman_code(57) -> {16#1f, 6};       %% '9'
huffman_code(58) -> {16#5c, 7};       %% ':'
huffman_code(59) -> {16#fb, 8};       %% ';'
huffman_code(60) -> {16#7ffc, 15};    %% '<'
huffman_code(61) -> {16#20, 6};       %% '='
huffman_code(62) -> {16#ffb, 12};     %% '>'
huffman_code(63) -> {16#3fc, 10};     %% '?'
huffman_code(64) -> {16#1ffa, 13};    %% '@'
huffman_code(65) -> {16#21, 6};       %% 'A'
huffman_code(66) -> {16#5d, 7};       %% 'B'
huffman_code(67) -> {16#5e, 7};       %% 'C'
huffman_code(68) -> {16#5f, 7};       %% 'D'
huffman_code(69) -> {16#60, 7};       %% 'E'
huffman_code(70) -> {16#61, 7};       %% 'F'
huffman_code(71) -> {16#62, 7};       %% 'G'
huffman_code(72) -> {16#63, 7};       %% 'H'
huffman_code(73) -> {16#64, 7};       %% 'I'
huffman_code(74) -> {16#65, 7};       %% 'J'
huffman_code(75) -> {16#66, 7};       %% 'K'
huffman_code(76) -> {16#67, 7};       %% 'L'
huffman_code(77) -> {16#68, 7};       %% 'M'
huffman_code(78) -> {16#69, 7};       %% 'N'
huffman_code(79) -> {16#6a, 7};       %% 'O'
huffman_code(80) -> {16#6b, 7};       %% 'P'
huffman_code(81) -> {16#6c, 7};       %% 'Q'
huffman_code(82) -> {16#6d, 7};       %% 'R'
huffman_code(83) -> {16#6e, 7};       %% 'S'
huffman_code(84) -> {16#6f, 7};       %% 'T'
huffman_code(85) -> {16#70, 7};       %% 'U'
huffman_code(86) -> {16#71, 7};       %% 'V'
huffman_code(87) -> {16#72, 7};       %% 'W'
huffman_code(88) -> {16#fc, 8};       %% 'X'
huffman_code(89) -> {16#73, 7};       %% 'Y'
huffman_code(90) -> {16#fd, 8};       %% 'Z'
huffman_code(91) -> {16#1ffb, 13};    %% '['
huffman_code(92) -> {16#7fff0, 19};   %% '\'
huffman_code(93) -> {16#1ffc, 13};    %% ']'
huffman_code(94) -> {16#3ffc, 14};    %% '^'
huffman_code(95) -> {16#22, 6};       %% '_'
huffman_code(96) -> {16#7ffd, 15};    %% '`'
huffman_code(97) -> {16#3, 5};        %% 'a'
huffman_code(98) -> {16#23, 6};       %% 'b'
huffman_code(99) -> {16#4, 5};        %% 'c'
huffman_code(100) -> {16#24, 6};      %% 'd'
huffman_code(101) -> {16#5, 5};       %% 'e'
huffman_code(102) -> {16#25, 6};      %% 'f'
huffman_code(103) -> {16#26, 6};      %% 'g'
huffman_code(104) -> {16#27, 6};      %% 'h'
huffman_code(105) -> {16#6, 5};       %% 'i'
huffman_code(106) -> {16#74, 7};      %% 'j'
huffman_code(107) -> {16#75, 7};      %% 'k'
huffman_code(108) -> {16#28, 6};      %% 'l'
huffman_code(109) -> {16#29, 6};      %% 'm'
huffman_code(110) -> {16#2a, 6};      %% 'n'
huffman_code(111) -> {16#7, 5};       %% 'o'
huffman_code(112) -> {16#2b, 6};      %% 'p'
huffman_code(113) -> {16#76, 7};      %% 'q'
huffman_code(114) -> {16#2c, 6};      %% 'r'
huffman_code(115) -> {16#8, 5};       %% 's'
huffman_code(116) -> {16#9, 5};       %% 't'
huffman_code(117) -> {16#2d, 6};      %% 'u'
huffman_code(118) -> {16#77, 7};      %% 'v'
huffman_code(119) -> {16#78, 7};      %% 'w'
huffman_code(120) -> {16#79, 7};      %% 'x'
huffman_code(121) -> {16#7a, 7};      %% 'y'
huffman_code(122) -> {16#7b, 7};      %% 'z'
huffman_code(123) -> {16#7ffe, 15};   %% '{'
huffman_code(124) -> {16#7fc, 11};    %% '|'
huffman_code(125) -> {16#3ffd, 14};   %% '}'
huffman_code(126) -> {16#1ffd, 13};   %% '~'
huffman_code(127) -> {16#ffffffc, 28};
huffman_code(128) -> {16#fffe6, 20};
huffman_code(129) -> {16#3fffd2, 22};
huffman_code(130) -> {16#fffe7, 20};
huffman_code(131) -> {16#fffe8, 20};
huffman_code(132) -> {16#3fffd3, 22};
huffman_code(133) -> {16#3fffd4, 22};
huffman_code(134) -> {16#3fffd5, 22};
huffman_code(135) -> {16#7fffd9, 23};
huffman_code(136) -> {16#3fffd6, 22};
huffman_code(137) -> {16#7fffda, 23};
huffman_code(138) -> {16#7fffdb, 23};
huffman_code(139) -> {16#7fffdc, 23};
huffman_code(140) -> {16#7fffdd, 23};
huffman_code(141) -> {16#7fffde, 23};
huffman_code(142) -> {16#ffffeb, 24};
huffman_code(143) -> {16#7fffdf, 23};
huffman_code(144) -> {16#ffffec, 24};
huffman_code(145) -> {16#ffffed, 24};
huffman_code(146) -> {16#3fffd7, 22};
huffman_code(147) -> {16#7fffe0, 23};
huffman_code(148) -> {16#ffffee, 24};
huffman_code(149) -> {16#7fffe1, 23};
huffman_code(150) -> {16#7fffe2, 23};
huffman_code(151) -> {16#7fffe3, 23};
huffman_code(152) -> {16#7fffe4, 23};
huffman_code(153) -> {16#1fffdc, 21};
huffman_code(154) -> {16#3fffd8, 22};
huffman_code(155) -> {16#7fffe5, 23};
huffman_code(156) -> {16#3fffd9, 22};
huffman_code(157) -> {16#7fffe6, 23};
huffman_code(158) -> {16#7fffe7, 23};
huffman_code(159) -> {16#ffffef, 24};
huffman_code(160) -> {16#3fffda, 22};
huffman_code(161) -> {16#1fffdd, 21};
huffman_code(162) -> {16#fffe9, 20};
huffman_code(163) -> {16#3fffdb, 22};
huffman_code(164) -> {16#3fffdc, 22};
huffman_code(165) -> {16#7fffe8, 23};
huffman_code(166) -> {16#7fffe9, 23};
huffman_code(167) -> {16#1fffde, 21};
huffman_code(168) -> {16#7fffea, 23};
huffman_code(169) -> {16#3fffdd, 22};
huffman_code(170) -> {16#3fffde, 22};
huffman_code(171) -> {16#fffff0, 24};
huffman_code(172) -> {16#1fffdf, 21};
huffman_code(173) -> {16#3fffdf, 22};
huffman_code(174) -> {16#7fffeb, 23};
huffman_code(175) -> {16#7fffec, 23};
huffman_code(176) -> {16#1fffe0, 21};
huffman_code(177) -> {16#1fffe1, 21};
huffman_code(178) -> {16#3fffe0, 22};
huffman_code(179) -> {16#1fffe2, 21};
huffman_code(180) -> {16#7fffed, 23};
huffman_code(181) -> {16#3fffe1, 22};
huffman_code(182) -> {16#7fffee, 23};
huffman_code(183) -> {16#7fffef, 23};
huffman_code(184) -> {16#fffea, 20};
huffman_code(185) -> {16#3fffe2, 22};
huffman_code(186) -> {16#3fffe3, 22};
huffman_code(187) -> {16#3fffe4, 22};
huffman_code(188) -> {16#7ffff0, 23};
huffman_code(189) -> {16#3fffe5, 22};
huffman_code(190) -> {16#3fffe6, 22};
huffman_code(191) -> {16#7ffff1, 23};
huffman_code(192) -> {16#3ffffe0, 26};
huffman_code(193) -> {16#3ffffe1, 26};
huffman_code(194) -> {16#fffeb, 20};
huffman_code(195) -> {16#7fff1, 19};
huffman_code(196) -> {16#3fffe7, 22};
huffman_code(197) -> {16#7ffff2, 23};
huffman_code(198) -> {16#3fffe8, 22};
huffman_code(199) -> {16#1ffffec, 25};
huffman_code(200) -> {16#3ffffe2, 26};
huffman_code(201) -> {16#3ffffe3, 26};
huffman_code(202) -> {16#3ffffe4, 26};
huffman_code(203) -> {16#7ffffde, 27};
huffman_code(204) -> {16#7ffffdf, 27};
huffman_code(205) -> {16#3ffffe5, 26};
huffman_code(206) -> {16#fffff1, 24};
huffman_code(207) -> {16#1ffffed, 25};
huffman_code(208) -> {16#7fff2, 19};
huffman_code(209) -> {16#1fffe3, 21};
huffman_code(210) -> {16#3ffffe6, 26};
huffman_code(211) -> {16#7ffffe0, 27};
huffman_code(212) -> {16#7ffffe1, 27};
huffman_code(213) -> {16#3ffffe7, 26};
huffman_code(214) -> {16#7ffffe2, 27};
huffman_code(215) -> {16#fffff2, 24};
huffman_code(216) -> {16#1fffe4, 21};
huffman_code(217) -> {16#1fffe5, 21};
huffman_code(218) -> {16#3ffffe8, 26};
huffman_code(219) -> {16#3ffffe9, 26};
huffman_code(220) -> {16#ffffffd, 28};
huffman_code(221) -> {16#7ffffe3, 27};
huffman_code(222) -> {16#7ffffe4, 27};
huffman_code(223) -> {16#7ffffe5, 27};
huffman_code(224) -> {16#fffec, 20};
huffman_code(225) -> {16#fffff3, 24};
huffman_code(226) -> {16#fffed, 20};
huffman_code(227) -> {16#1fffe6, 21};
huffman_code(228) -> {16#3fffe9, 22};
huffman_code(229) -> {16#1fffe7, 21};
huffman_code(230) -> {16#1fffe8, 21};
huffman_code(231) -> {16#7ffff3, 23};
huffman_code(232) -> {16#3fffea, 22};
huffman_code(233) -> {16#3fffeb, 22};
huffman_code(234) -> {16#1ffffee, 25};
huffman_code(235) -> {16#1ffffef, 25};
huffman_code(236) -> {16#fffff4, 24};
huffman_code(237) -> {16#fffff5, 24};
huffman_code(238) -> {16#3ffffea, 26};
huffman_code(239) -> {16#7ffff4, 23};
huffman_code(240) -> {16#3ffffeb, 26};
huffman_code(241) -> {16#7ffffe6, 27};
huffman_code(242) -> {16#3ffffec, 26};
huffman_code(243) -> {16#3ffffed, 26};
huffman_code(244) -> {16#7ffffe7, 27};
huffman_code(245) -> {16#7ffffe8, 27};
huffman_code(246) -> {16#7ffffe9, 27};
huffman_code(247) -> {16#7ffffea, 27};
huffman_code(248) -> {16#7ffffeb, 27};
huffman_code(249) -> {16#ffffffe, 28};
huffman_code(250) -> {16#7ffffec, 27};
huffman_code(251) -> {16#7ffffed, 27};
huffman_code(252) -> {16#7ffffee, 27};
huffman_code(253) -> {16#7ffffef, 27};
huffman_code(254) -> {16#7fffff0, 27};
huffman_code(255) -> {16#3ffffee, 26}.
