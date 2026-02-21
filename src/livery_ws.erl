%% @doc WebSocket frame encoding/decoding and connection handling (RFC 6455).
%%
%% Supports:
%% - Text and binary frames
%% - Ping/pong for keepalive
%% - Fragmented messages
%% - Close frames with status codes
-module(livery_ws).

-export([
    %% Handshake
    upgrade_key/1,
    is_upgrade_request/1,
    handshake_response/1,
    %% Frame encoding
    encode_frame/1,
    encode_frame/2,
    encode_text/1,
    encode_binary/1,
    encode_ping/0,
    encode_ping/1,
    encode_pong/1,
    encode_close/0,
    encode_close/1,
    encode_close/2,
    %% Frame decoding
    decode_frame/1,
    %% Masking
    mask/2,
    unmask/2
]).

%% WebSocket opcodes
-define(OP_CONTINUATION, 16#0).
-define(OP_TEXT, 16#1).
-define(OP_BINARY, 16#2).
-define(OP_CLOSE, 16#8).
-define(OP_PING, 16#9).
-define(OP_PONG, 16#A).

%% WebSocket GUID for handshake
-define(WS_GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).

-type opcode() :: text | binary | close | ping | pong | continuation.
-type frame() :: {opcode(), binary()} | {opcode(), binary(), boolean()}.

-export_type([opcode/0, frame/0]).

%%====================================================================
%% Handshake
%%====================================================================

%% @doc Check if request is a WebSocket upgrade request.
-spec is_upgrade_request([{binary(), binary()}]) -> boolean().
is_upgrade_request(Headers) ->
    has_header_value(<<"upgrade">>, <<"websocket">>, Headers) andalso
    has_header_value(<<"connection">>, <<"upgrade">>, Headers) andalso
    has_header(<<"sec-websocket-key">>, Headers) andalso
    has_header_value(<<"sec-websocket-version">>, <<"13">>, Headers).

%% @doc Calculate the Sec-WebSocket-Accept response key.
-spec upgrade_key(binary()) -> binary().
upgrade_key(Key) ->
    base64:encode(crypto:hash(sha, <<Key/binary, ?WS_GUID/binary>>)).

%% @doc Build WebSocket handshake response headers.
-spec handshake_response(binary()) -> [{binary(), binary()}].
handshake_response(ClientKey) ->
    AcceptKey = upgrade_key(ClientKey),
    [
        {<<"upgrade">>, <<"websocket">>},
        {<<"connection">>, <<"Upgrade">>},
        {<<"sec-websocket-accept">>, AcceptKey}
    ].

%%====================================================================
%% Frame Encoding (Server -> Client, unmasked)
%%====================================================================

%% @doc Encode a WebSocket frame.
-spec encode_frame(frame()) -> binary().
encode_frame({Opcode, Payload}) ->
    encode_frame(Opcode, Payload);
encode_frame({Opcode, Payload, Fin}) ->
    encode_frame_internal(opcode_to_int(Opcode), Payload, Fin).

%% @doc Encode a WebSocket frame with opcode and payload.
-spec encode_frame(opcode(), binary()) -> binary().
encode_frame(Opcode, Payload) ->
    encode_frame_internal(opcode_to_int(Opcode), Payload, true).

%% @doc Encode a text frame.
-spec encode_text(binary()) -> binary().
encode_text(Text) ->
    encode_frame(text, Text).

%% @doc Encode a binary frame.
-spec encode_binary(binary()) -> binary().
encode_binary(Data) ->
    encode_frame(binary, Data).

%% @doc Encode a ping frame with no payload.
-spec encode_ping() -> binary().
encode_ping() ->
    encode_ping(<<>>).

%% @doc Encode a ping frame with payload.
-spec encode_ping(binary()) -> binary().
encode_ping(Payload) ->
    encode_frame(ping, Payload).

%% @doc Encode a pong frame.
-spec encode_pong(binary()) -> binary().
encode_pong(Payload) ->
    encode_frame(pong, Payload).

%% @doc Encode a close frame with no status.
-spec encode_close() -> binary().
encode_close() ->
    encode_frame(close, <<>>).

%% @doc Encode a close frame with status code.
-spec encode_close(non_neg_integer()) -> binary().
encode_close(StatusCode) ->
    encode_frame(close, <<StatusCode:16>>).

%% @doc Encode a close frame with status code and reason.
-spec encode_close(non_neg_integer(), binary()) -> binary().
encode_close(StatusCode, Reason) ->
    encode_frame(close, <<StatusCode:16, Reason/binary>>).

%% Internal: encode frame with FIN flag
encode_frame_internal(Opcode, Payload, Fin) ->
    FinBit = case Fin of true -> 1; false -> 0 end,
    Len = byte_size(Payload),
    Header = if
        Len < 126 ->
            <<FinBit:1, 0:3, Opcode:4, 0:1, Len:7>>;
        Len < 65536 ->
            <<FinBit:1, 0:3, Opcode:4, 0:1, 126:7, Len:16>>;
        true ->
            <<FinBit:1, 0:3, Opcode:4, 0:1, 127:7, Len:64>>
    end,
    <<Header/binary, Payload/binary>>.

%%====================================================================
%% Frame Decoding (Client -> Server, masked)
%%====================================================================

%% @doc Decode a WebSocket frame.
%% Returns {ok, Opcode, Payload, Fin, Rest} | {more, N} | {error, Reason}.
-spec decode_frame(binary()) ->
    {ok, opcode(), binary(), boolean(), binary()} |
    {more, non_neg_integer()} |
    {error, term()}.
decode_frame(<<Fin:1, _Rsv:3, Opcode:4, Mask:1, Len:7, Rest/binary>>) ->
    decode_frame_len(Fin, Opcode, Mask, Len, Rest);
decode_frame(Data) when byte_size(Data) < 2 ->
    {more, 2 - byte_size(Data)};
decode_frame(_) ->
    {error, invalid_frame}.

decode_frame_len(Fin, Opcode, Mask, 126, <<Len:16, Rest/binary>>) ->
    decode_frame_payload(Fin, Opcode, Mask, Len, Rest);
decode_frame_len(_Fin, _Opcode, Mask, 126, Rest) ->
    {more, 2 + mask_size(Mask) - byte_size(Rest)};
decode_frame_len(Fin, Opcode, Mask, 127, <<Len:64, Rest/binary>>) ->
    decode_frame_payload(Fin, Opcode, Mask, Len, Rest);
decode_frame_len(_Fin, _Opcode, Mask, 127, Rest) ->
    {more, 8 + mask_size(Mask) - byte_size(Rest)};
decode_frame_len(Fin, Opcode, Mask, Len, Rest) ->
    decode_frame_payload(Fin, Opcode, Mask, Len, Rest).

decode_frame_payload(Fin, Opcode, 1, Len, <<MaskKey:4/binary, Rest/binary>>)
  when byte_size(Rest) >= Len ->
    <<Masked:Len/binary, Remaining/binary>> = Rest,
    Payload = unmask(Masked, MaskKey),
    FinBool = Fin =:= 1,
    {ok, int_to_opcode(Opcode), Payload, FinBool, Remaining};
decode_frame_payload(Fin, Opcode, 0, Len, Rest) when byte_size(Rest) >= Len ->
    <<Payload:Len/binary, Remaining/binary>> = Rest,
    FinBool = Fin =:= 1,
    {ok, int_to_opcode(Opcode), Payload, FinBool, Remaining};
decode_frame_payload(_Fin, _Opcode, Mask, Len, Rest) ->
    Needed = Len + mask_size(Mask) - byte_size(Rest),
    {more, Needed}.

mask_size(1) -> 4;
mask_size(0) -> 0.

%%====================================================================
%% Masking
%%====================================================================

%% @doc Mask data with the given key (for client -> server).
-spec mask(binary(), binary()) -> binary().
mask(Data, MaskKey) ->
    do_mask(Data, MaskKey, <<>>).

%% @doc Unmask data with the given key (same as mask, XOR is symmetric).
-spec unmask(binary(), binary()) -> binary().
unmask(Data, MaskKey) ->
    mask(Data, MaskKey).

do_mask(<<>>, _MaskKey, Acc) ->
    Acc;
do_mask(<<D:32, Rest/binary>>, <<M:32>> = MaskKey, Acc) ->
    do_mask(Rest, MaskKey, <<Acc/binary, (D bxor M):32>>);
do_mask(<<D:24>>, <<M1:8, M2:8, M3:8, _:8>>, Acc) ->
    M = (M1 bsl 16) bor (M2 bsl 8) bor M3,
    <<Acc/binary, (D bxor M):24>>;
do_mask(<<D:16>>, <<M1:8, M2:8, _:16>>, Acc) ->
    M = (M1 bsl 8) bor M2,
    <<Acc/binary, (D bxor M):16>>;
do_mask(<<D:8>>, <<M:8, _:24>>, Acc) ->
    <<Acc/binary, (D bxor M):8>>.

%%====================================================================
%% Internal - Opcode conversion
%%====================================================================

opcode_to_int(continuation) -> ?OP_CONTINUATION;
opcode_to_int(text) -> ?OP_TEXT;
opcode_to_int(binary) -> ?OP_BINARY;
opcode_to_int(close) -> ?OP_CLOSE;
opcode_to_int(ping) -> ?OP_PING;
opcode_to_int(pong) -> ?OP_PONG.

int_to_opcode(?OP_CONTINUATION) -> continuation;
int_to_opcode(?OP_TEXT) -> text;
int_to_opcode(?OP_BINARY) -> binary;
int_to_opcode(?OP_CLOSE) -> close;
int_to_opcode(?OP_PING) -> ping;
int_to_opcode(?OP_PONG) -> pong;
int_to_opcode(N) -> {unknown, N}.

%%====================================================================
%% Internal - Header helpers
%%====================================================================

has_header(Name, Headers) ->
    LowerName = string:lowercase(Name),
    lists:any(fun({K, _V}) ->
        string:lowercase(K) =:= LowerName
    end, Headers).

has_header_value(Name, Value, Headers) ->
    LowerName = string:lowercase(Name),
    LowerValue = string:lowercase(Value),
    lists:any(fun({K, V}) ->
        string:lowercase(K) =:= LowerName andalso
        contains_value(string:lowercase(V), LowerValue)
    end, Headers).

%% Check if header value contains the target (handles comma-separated values)
contains_value(HeaderValue, Target) ->
    Values = binary:split(HeaderValue, [<<",">>, <<" ">>], [global, trim_all]),
    lists:any(fun(V) -> string:lowercase(V) =:= Target end, Values).
