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
encode_string(String) when is_binary(String) ->
    %% For now, use literal encoding without Huffman
    %% TODO: Add Huffman encoding for better compression
    Len = byte_size(String),
    if
        Len < 127 ->
            [<<0:1, Len:7>>, String];
        true ->
            [<<0:1, 127:7>> | encode_integer_rest(Len - 127)] ++ [String]
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

huffman_decode_bits(<<>>, 0, Rest, Acc, Bits, Code) ->
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

%% Huffman lookup table (subset for common ASCII)
huffman_lookup(2#00000, 5) -> {ok, $0};
huffman_lookup(2#00001, 5) -> {ok, $1};
huffman_lookup(2#00010, 5) -> {ok, $2};
huffman_lookup(2#00011, 5) -> {ok, $a};
huffman_lookup(2#00100, 5) -> {ok, $c};
huffman_lookup(2#00101, 5) -> {ok, $e};
huffman_lookup(2#00110, 5) -> {ok, $i};
huffman_lookup(2#00111, 5) -> {ok, $o};
huffman_lookup(2#01000, 5) -> {ok, $s};
huffman_lookup(2#01001, 5) -> {ok, $t};
huffman_lookup(2#01010, 6) -> {ok, $ };
huffman_lookup(2#010110, 6) -> {ok, $%};
huffman_lookup(2#010111, 6) -> {ok, $-};
huffman_lookup(2#011000, 6) -> {ok, $.};
huffman_lookup(2#011001, 6) -> {ok, $/};
huffman_lookup(2#011010, 6) -> {ok, $3};
huffman_lookup(2#011011, 6) -> {ok, $4};
huffman_lookup(2#011100, 6) -> {ok, $5};
huffman_lookup(2#011101, 6) -> {ok, $6};
huffman_lookup(2#011110, 6) -> {ok, $7};
huffman_lookup(2#011111, 6) -> {ok, $8};
huffman_lookup(2#100000, 6) -> {ok, $9};
huffman_lookup(2#100001, 6) -> {ok, $=};
huffman_lookup(2#100010, 6) -> {ok, $A};
huffman_lookup(2#100011, 6) -> {ok, $_};
huffman_lookup(2#100100, 6) -> {ok, $b};
huffman_lookup(2#100101, 6) -> {ok, $d};
huffman_lookup(2#100110, 6) -> {ok, $f};
huffman_lookup(2#100111, 6) -> {ok, $g};
huffman_lookup(2#101000, 6) -> {ok, $h};
huffman_lookup(2#101001, 6) -> {ok, $l};
huffman_lookup(2#101010, 6) -> {ok, $m};
huffman_lookup(2#101011, 6) -> {ok, $n};
huffman_lookup(2#101100, 6) -> {ok, $p};
huffman_lookup(2#101101, 6) -> {ok, $r};
huffman_lookup(2#101110, 6) -> {ok, $u};
huffman_lookup(2#1111111111111111111111111111, 30) -> eos;
huffman_lookup(_Code, Bits) when Bits >= 30 -> error;
huffman_lookup(_, _) -> continue.
