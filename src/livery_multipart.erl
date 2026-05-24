-module(livery_multipart).
-moduledoc """
Streaming `multipart/form-data` parser (RFC 7578).

Sits on the request body reader (`livery_body`) and works over both
streamed (`{stream, _}`) and buffered (`{buffered, _}`) bodies. Pull the
parts one at a time:

```erlang
{ok, MP0} = livery_multipart:new(Req),
case livery_multipart:next_part(MP0, 5000) of
    {part, #{name := Name, filename := File}, MP1} ->
        %% drain this part's body incrementally
        drain(MP1);
    {done, _} -> ok
end.
```

`read_all/1,2` is a convenience that collects every part fully into
memory under the configured limits.

Security: the parser bounds all buffering (`max_header_bytes`,
`max_header_count`, `max_parts`, `max_part_size`, `max_body`) and never
touches the filesystem. A part's `filename` is returned verbatim; a
handler MUST confine/sanitize it before using it as a path.
""".

-include("livery.hrl").

-export([
    new/1,
    new/2,
    next_part/1,
    next_part/2,
    read_part/2,
    read_all/1,
    read_all/2
]).

-export_type([mp/0, part/0, part_full/0, opts/0, reason/0]).

-record(mp, {
    reader :: livery_body:reader() | undefined,
    dash :: binary(),
    crlfdash :: binary(),
    buffer = <<>> :: binary(),
    state = start :: start | after_boundary | body | closed,
    opts :: opts(),
    timeout = 5000 :: timeout(),
    consumed = 0 :: non_neg_integer(),
    parts = 0 :: non_neg_integer()
}).

-opaque mp() :: #mp{}.

-type opts() :: #{
    part_timeout => timeout(),
    max_parts => pos_integer(),
    max_header_bytes => pos_integer(),
    max_header_count => pos_integer(),
    max_part_size => pos_integer(),
    max_body => pos_integer()
}.

-type part() :: #{
    name := binary() | undefined,
    filename := binary() | undefined,
    content_type := binary() | undefined,
    headers := [{binary(), binary()}]
}.

-type part_full() :: #{
    name := binary() | undefined,
    filename := binary() | undefined,
    content_type := binary() | undefined,
    headers := [{binary(), binary()}],
    body := binary()
}.

-type reason() ::
    malformed
    | {client_reset, term()}
    | timeout
    | {limit,
        max_parts
        | max_header_bytes
        | max_header_count
        | max_part_size
        | max_body}.

-define(CRLF, <<"\r\n">>).

%%====================================================================
%% Construction
%%====================================================================

-doc "Build a parser from a request. Reads the boundary from Content-Type.".
-spec new(livery_req:req()) -> {ok, mp()} | {error, not_multipart | no_boundary}.
new(Req) ->
    new(Req, #{}).

-doc "`new/1` with parser options.".
-spec new(livery_req:req(), opts()) ->
    {ok, mp()} | {error, not_multipart | no_boundary}.
new(Req, Opts0) ->
    Opts = maps:merge(default_opts(), Opts0),
    case livery_req:header(<<"content-type">>, Req) of
        undefined ->
            {error, not_multipart};
        Value ->
            case multipart_boundary(Value) of
                {ok, Boundary} -> {ok, init_mp(Req, Boundary, Opts)};
                {error, R} -> {error, R}
            end
    end.

-spec init_mp(livery_req:req(), binary(), opts()) -> mp().
init_mp(Req, Boundary, Opts) ->
    {Buffer, Reader, Consumed} = source(Req),
    #mp{
        reader = Reader,
        dash = <<"--", Boundary/binary>>,
        crlfdash = <<"\r\n--", Boundary/binary>>,
        buffer = Buffer,
        opts = Opts,
        timeout = maps:get(part_timeout, Opts),
        consumed = Consumed
    }.

-spec source(livery_req:req()) ->
    {binary(), livery_body:reader() | undefined, non_neg_integer()}.
source(Req) ->
    case livery_req:body(Req) of
        empty ->
            {<<>>, undefined, 0};
        {buffered, IoData} ->
            Bin = iolist_to_binary(IoData),
            {Bin, undefined, byte_size(Bin)};
        {stream, Reader} ->
            {<<>>, Reader, 0}
    end.

%%====================================================================
%% Streaming API
%%====================================================================

-doc "Advance to the next part, returning its parsed metadata.".
-spec next_part(mp()) -> {part, part(), mp()} | {done, mp()} | {error, reason(), mp()}.
next_part(MP) ->
    next_part(MP, MP#mp.timeout).

-doc "`next_part/1` with an explicit per-chunk timeout.".
-spec next_part(mp(), timeout()) ->
    {part, part(), mp()} | {done, mp()} | {error, reason(), mp()}.
next_part(#mp{} = MP0, Timeout) ->
    MP = MP0#mp{timeout = Timeout},
    case max_body_ok(MP) of
        false -> {error, {limit, max_body}, MP};
        true -> advance(MP)
    end.

-spec advance(mp()) -> {part, part(), mp()} | {done, mp()} | {error, reason(), mp()}.
advance(#mp{state = closed} = MP) ->
    {done, MP};
advance(#mp{state = start} = MP) ->
    case start_scan(MP) of
        {ok, MP1} -> at_boundary(MP1);
        {done, MP1} -> {done, MP1};
        {error, R, MP1} -> {error, R, MP1}
    end;
advance(#mp{state = body} = MP) ->
    case skip_body(MP) of
        {ok, MP1} -> at_boundary(MP1);
        {error, R, MP1} -> {error, R, MP1}
    end;
advance(#mp{state = after_boundary} = MP) ->
    at_boundary(MP).

%% Positioned right after a `--boundary` token: decide closing vs a part.
-spec at_boundary(mp()) ->
    {part, part(), mp()} | {done, mp()} | {error, reason(), mp()}.
at_boundary(MP0) ->
    case ensure(MP0, 2) of
        {ok, MP} ->
            case MP#mp.buffer of
                <<"--", _/binary>> ->
                    {done, MP#mp{state = closed, buffer = <<>>}};
                _ ->
                    start_part(MP)
            end;
        {eof, MP} ->
            %% boundary not followed by anything: tolerate as closing.
            {done, MP#mp{state = closed, buffer = <<>>}};
        {error, R, MP} ->
            {error, R, MP}
    end.

-spec start_part(mp()) -> {part, part(), mp()} | {error, reason(), mp()}.
start_part(MP0) ->
    MaxParts = maps:get(max_parts, MP0#mp.opts),
    case MP0#mp.parts + 1 > MaxParts of
        true ->
            {error, {limit, max_parts}, MP0};
        false ->
            %% consume the rest of the boundary line (transport padding)
            case read_line(MP0, maps:get(max_header_bytes, MP0#mp.opts)) of
                {line, _Padding, MP1} -> read_part_headers(MP1);
                {error, R, MP1} -> {error, R, MP1}
            end
    end.

-spec read_part_headers(mp()) -> {part, part(), mp()} | {error, reason(), mp()}.
read_part_headers(MP0) ->
    Max = maps:get(max_header_bytes, MP0#mp.opts),
    MaxCount = maps:get(max_header_count, MP0#mp.opts),
    case headers_loop(MP0, [], 0, Max, MaxCount) of
        {ok, Headers, MP1} ->
            Part = build_part(Headers),
            {part, Part, MP1#mp{state = body, parts = MP1#mp.parts + 1}};
        {error, R, MP1} ->
            {error, R, MP1}
    end.

-spec headers_loop(mp(), [{binary(), binary()}], non_neg_integer(), pos_integer(), pos_integer()) ->
    {ok, [{binary(), binary()}], mp()} | {error, reason(), mp()}.
headers_loop(MP0, Acc, Bytes, Max, MaxCount) ->
    case read_line(MP0, Max) of
        {line, <<>>, MP1} ->
            {ok, lists:reverse(Acc), MP1};
        {line, Line, MP1} ->
            NewBytes = Bytes + byte_size(Line) + 2,
            check_header_line(MP1, Acc, Line, NewBytes, Max, MaxCount);
        {error, R, MP1} ->
            {error, R, MP1}
    end.

-spec check_header_line(
    mp(), [{binary(), binary()}], binary(), non_neg_integer(), pos_integer(), pos_integer()
) -> {ok, [{binary(), binary()}], mp()} | {error, reason(), mp()}.
check_header_line(MP, _Acc, _Line, NewBytes, Max, _MaxCount) when NewBytes > Max ->
    {error, {limit, max_header_bytes}, MP};
check_header_line(MP, Acc, _Line, _NewBytes, _Max, MaxCount) when
    length(Acc) + 1 > MaxCount
->
    {error, {limit, max_header_count}, MP};
check_header_line(MP, Acc, Line, NewBytes, Max, MaxCount) ->
    case parse_header(Line) of
        {ok, KV} -> headers_loop(MP, [KV | Acc], NewBytes, Max, MaxCount);
        error -> {error, malformed, MP}
    end.

-doc "Read the next chunk of the current part body.".
-spec read_part(mp(), timeout()) ->
    {ok, binary(), mp()} | {done, mp()} | {error, reason(), mp()}.
read_part(#mp{state = body} = MP0, Timeout) ->
    body_chunk(MP0#mp{timeout = Timeout});
read_part(#mp{} = MP, _Timeout) ->
    {done, MP}.

-spec body_chunk(mp()) -> {ok, binary(), mp()} | {done, mp()} | {error, reason(), mp()}.
body_chunk(#mp{buffer = Buf, crlfdash = Needle} = MP) ->
    case binary:match(Buf, Needle) of
        {Pos, Len} ->
            <<Body:Pos/binary, _:Len/binary, Rest/binary>> = Buf,
            MP1 = MP#mp{buffer = Rest, state = after_boundary},
            case Pos of
                0 -> {done, MP1};
                _ -> {ok, Body, MP1}
            end;
        nomatch ->
            HoldBack = byte_size(MP#mp.crlfdash) - 1,
            case byte_size(Buf) > HoldBack of
                true ->
                    Emit = binary:part(Buf, 0, byte_size(Buf) - HoldBack),
                    Keep = binary:part(Buf, byte_size(Buf) - HoldBack, HoldBack),
                    {ok, Emit, MP#mp{buffer = Keep}};
                false ->
                    case pull(MP) of
                        {ok, MP1} -> body_chunk(MP1);
                        {eof, MP1} -> {error, malformed, MP1};
                        {error, R, MP1} -> {error, R, MP1}
                    end
            end
    end.

-spec skip_body(mp()) -> {ok, mp()} | {error, reason(), mp()}.
skip_body(MP0) ->
    case read_part(MP0, MP0#mp.timeout) of
        {ok, _Chunk, MP1} -> skip_body(MP1);
        {done, MP1} -> {ok, MP1};
        {error, R, MP1} -> {error, R, MP1}
    end.

%%====================================================================
%% Buffered convenience
%%====================================================================

-doc "Collect every part fully into memory under the configured limits.".
-spec read_all(livery_req:req()) -> {ok, [part_full()]} | {error, reason()}.
read_all(Req) ->
    read_all(Req, #{}).

-doc "`read_all/1` with parser options.".
-spec read_all(livery_req:req(), opts()) -> {ok, [part_full()]} | {error, reason()}.
read_all(Req, Opts) ->
    case new(Req, Opts) of
        {error, R} -> {error, R};
        {ok, MP} -> collect(MP, [])
    end.

-spec collect(mp(), [part_full()]) -> {ok, [part_full()]} | {error, reason()}.
collect(MP0, Acc) ->
    case next_part(MP0) of
        {done, _MP1} ->
            {ok, lists:reverse(Acc)};
        {error, R, _MP1} ->
            {error, R};
        {part, Part, MP1} ->
            Max = maps:get(max_part_size, MP1#mp.opts),
            case collect_body(MP1, [], 0, Max) of
                {ok, Body, MP2} ->
                    collect(MP2, [Part#{body => Body} | Acc]);
                {error, R, _MP2} ->
                    {error, R}
            end
    end.

-spec collect_body(mp(), [binary()], non_neg_integer(), pos_integer()) ->
    {ok, binary(), mp()} | {error, reason(), mp()}.
collect_body(MP0, Acc, Size, Max) ->
    case read_part(MP0, MP0#mp.timeout) of
        {ok, Chunk, MP1} ->
            Size1 = Size + byte_size(Chunk),
            case Size1 > Max of
                true -> {error, {limit, max_part_size}, MP1};
                false -> collect_body(MP1, [Chunk | Acc], Size1, Max)
            end;
        {done, MP1} ->
            {ok, iolist_to_binary(lists:reverse(Acc)), MP1};
        {error, R, MP1} ->
            {error, R, MP1}
    end.

%%====================================================================
%% Scanning primitives
%%====================================================================

%% Skip the preamble, locate the first `--boundary`, position after it.
-spec start_scan(mp()) -> {ok, mp()} | {done, mp()} | {error, reason(), mp()}.
start_scan(#mp{buffer = Buf, dash = Dash} = MP) ->
    case binary:match(Buf, Dash) of
        {Pos, Len} ->
            Rest = binary:part(Buf, Pos + Len, byte_size(Buf) - Pos - Len),
            {ok, MP#mp{buffer = Rest, state = after_boundary}};
        nomatch ->
            HoldBack = byte_size(Dash) - 1,
            Keep = tail(Buf, HoldBack),
            case pull(MP#mp{buffer = Keep}) of
                {ok, MP1} ->
                    start_scan(MP1);
                {eof, MP1} ->
                    case MP1#mp.consumed of
                        0 -> {done, MP1#mp{state = closed}};
                        _ -> {error, malformed, MP1}
                    end;
                {error, R, MP1} ->
                    {error, R, MP1}
            end
    end.

%% Read one CRLF-terminated line, returning the content before the CRLF.
-spec read_line(mp(), integer()) -> {line, binary(), mp()} | {error, reason(), mp()}.
read_line(#mp{buffer = Buf} = MP, MaxBytes) ->
    case binary:match(Buf, ?CRLF) of
        {Pos, Len} ->
            <<Line:Pos/binary, _:Len/binary, Rest/binary>> = Buf,
            {line, Line, MP#mp{buffer = Rest}};
        nomatch ->
            case byte_size(Buf) > MaxBytes of
                true ->
                    {error, {limit, max_header_bytes}, MP};
                false ->
                    case pull(MP) of
                        {ok, MP1} -> read_line(MP1, MaxBytes);
                        {eof, MP1} -> {error, malformed, MP1};
                        {error, R, MP1} -> {error, R, MP1}
                    end
            end
    end.

%% Ensure at least N bytes are buffered (or EOF/error).
-spec ensure(mp(), non_neg_integer()) -> {ok, mp()} | {eof, mp()} | {error, reason(), mp()}.
ensure(#mp{buffer = Buf} = MP, N) when byte_size(Buf) >= N ->
    {ok, MP};
ensure(MP, N) ->
    case pull(MP) of
        {ok, MP1} -> ensure(MP1, N);
        {eof, MP1} -> {eof, MP1};
        {error, R, MP1} -> {error, R, MP1}
    end.

%% Read one chunk from the source into the buffer.
-spec pull(mp()) -> {ok, mp()} | {eof, mp()} | {error, reason(), mp()}.
pull(#mp{reader = undefined} = MP) ->
    {eof, MP};
pull(#mp{reader = Reader, timeout = Timeout, buffer = Buf, consumed = Consumed} = MP) ->
    case livery_body:read(Reader, Timeout) of
        {ok, Chunk, Reader1} ->
            Bin = iolist_to_binary(Chunk),
            MP1 = MP#mp{
                reader = Reader1,
                buffer = <<Buf/binary, Bin/binary>>,
                consumed = Consumed + byte_size(Bin)
            },
            case max_body_ok(MP1) of
                true -> {ok, MP1};
                false -> {error, {limit, max_body}, MP1}
            end;
        {done, Reader1} ->
            {eof, MP#mp{reader = Reader1}};
        {error, Error, Reader1} ->
            {error, normalize_error(Error), MP#mp{reader = Reader1}}
    end.

-spec max_body_ok(mp()) -> boolean().
max_body_ok(#mp{consumed = C, opts = Opts}) ->
    C =< maps:get(max_body, Opts).

-spec normalize_error(timeout | {client_reset, term()}) -> reason().
normalize_error(timeout) -> timeout;
normalize_error({client_reset, _} = E) -> E.

-spec tail(binary(), non_neg_integer()) -> binary().
tail(Bin, N) when byte_size(Bin) =< N -> Bin;
tail(Bin, N) -> binary:part(Bin, byte_size(Bin) - N, N).

%%====================================================================
%% Header / part parsing
%%====================================================================

-spec parse_header(binary()) -> {ok, {binary(), binary()}} | error.
parse_header(Line) ->
    case has_control(Line) of
        true ->
            error;
        false ->
            case binary:split(Line, <<":">>) of
                [Name, Value] when Name =/= <<>> ->
                    {ok, {downcase(trim(Name)), trim(Value)}};
                _ ->
                    error
            end
    end.

-spec build_part([{binary(), binary()}]) -> part().
build_part(Headers) ->
    {Name, Filename} =
        case lists:keyfind(<<"content-disposition">>, 1, Headers) of
            {_, CD} -> disposition(CD);
            false -> {undefined, undefined}
        end,
    CType =
        case lists:keyfind(<<"content-type">>, 1, Headers) of
            {_, CT} -> CT;
            false -> undefined
        end,
    #{
        name => Name,
        filename => Filename,
        content_type => CType,
        headers => Headers
    }.

-spec disposition(binary()) -> {binary() | undefined, binary() | undefined}.
disposition(Value) ->
    Params = params(Value),
    {param(<<"name">>, Params), param(<<"filename">>, Params)}.

-spec param(binary(), [{binary(), binary()}]) -> binary() | undefined.
param(Key, Params) ->
    case lists:keyfind(Key, 1, Params) of
        {_, V} -> V;
        false -> undefined
    end.

%% Parse `;`-separated parameters after the leading token, unquoting
%% double-quoted values. Keys are lowercased.
-spec params(binary()) -> [{binary(), binary()}].
params(Value) ->
    case binary:split(Value, <<";">>, [global]) of
        [_Type | Rest] -> lists:filtermap(fun param_pair/1, Rest);
        [] -> []
    end.

-spec param_pair(binary()) -> {true, {binary(), binary()}} | false.
param_pair(Part) ->
    case binary:split(trim(Part), <<"=">>) of
        [K, V] when K =/= <<>> -> {true, {downcase(trim(K)), unquote(trim(V))}};
        _ -> false
    end.

-spec unquote(binary()) -> binary().
unquote(<<$", Rest/binary>>) ->
    case byte_size(Rest) of
        0 ->
            Rest;
        N ->
            case binary:at(Rest, N - 1) of
                $" -> binary:part(Rest, 0, N - 1);
                _ -> <<$", Rest/binary>>
            end
    end;
unquote(V) ->
    V.

%%====================================================================
%% Content-Type / boundary
%%====================================================================

-spec multipart_boundary(binary()) ->
    {ok, binary()} | {error, not_multipart | no_boundary}.
multipart_boundary(Value) ->
    case binary:split(Value, <<";">>) of
        [Type | _] ->
            case downcase(trim(Type)) of
                <<"multipart/form-data">> -> boundary_param(Value);
                _ -> {error, not_multipart}
            end;
        [] ->
            {error, not_multipart}
    end.

-spec boundary_param(binary()) -> {ok, binary()} | {error, no_boundary}.
boundary_param(Value) ->
    case param(<<"boundary">>, params(Value)) of
        undefined -> {error, no_boundary};
        <<>> -> {error, no_boundary};
        Boundary -> {ok, Boundary}
    end.

%%====================================================================
%% Helpers
%%====================================================================

-spec default_opts() -> opts().
default_opts() ->
    #{
        part_timeout => 5000,
        max_parts => 1000,
        max_header_bytes => 65536,
        max_header_count => 64,
        max_part_size => 10485760,
        max_body => 104857600
    }.

-spec has_control(binary()) -> boolean().
has_control(<<>>) -> false;
has_control(<<C, _/binary>>) when C < 32, C =/= $\t -> true;
has_control(<<_, Rest/binary>>) -> has_control(Rest).

-spec trim(binary()) -> binary().
trim(Bin) ->
    iolist_to_binary(string:trim(Bin)).

-spec downcase(binary()) -> binary().
downcase(Bin) ->
    iolist_to_binary(string:lowercase(Bin)).
