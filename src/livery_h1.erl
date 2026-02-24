%% @doc HTTP/1.x protocol handler.
%%
%% Handles HTTP/1.0 and HTTP/1.1 protocol logic.
-module(livery_h1).

-include("livery.hrl").

-export([
    init/2,
    handle_data/2,
    continue_sent/1,
    send_response/5,
    send_stream/5,
    close/1
]).

-record(h1_state, {
    buffer = <<>> :: binary(),
    req :: #livery_req{} | undefined,
    handler :: module(),
    handler_opts :: term(),
    handler_state :: term(),
    keepalive = true :: boolean(),
    request_count = 0 :: non_neg_integer(),
    limits :: livery_h1_parse:limits(),
    %% Chunked body parsing state
    body_state :: undefined | {chunked, [binary()], non_neg_integer()} | {chunked_trailers, [binary()]},
    body_remaining :: non_neg_integer() | undefined,
    max_body_size :: non_neg_integer(),
    max_chunk_size :: non_neg_integer(),
    %% Expect: 100-continue handling
    expect_continue = false :: boolean(),
    continue_sent = false :: boolean()
}).

-opaque state() :: #h1_state{}.
-export_type([state/0]).

%% @doc Initialize HTTP/1.x protocol state.
-spec init(module(), term()) -> state().
init(Handler, HandlerOpts) ->
    Limits = #{
        max_method_size => application:get_env(livery, max_method_size, ?MAX_METHOD_SIZE),
        max_uri_size => application:get_env(livery, max_request_line_size, ?MAX_URI_SIZE),
        max_header_name_size => application:get_env(livery, max_header_name_size, ?MAX_HEADER_NAME_SIZE),
        max_header_value_size => application:get_env(livery, max_header_value_size, ?MAX_HEADER_VALUE_SIZE),
        max_headers => application:get_env(livery, max_headers, ?MAX_HEADERS)
    },
    #h1_state{
        handler = Handler,
        handler_opts = HandlerOpts,
        limits = Limits,
        max_body_size = application:get_env(livery, max_body_size, ?MAX_BODY_SIZE),
        max_chunk_size = application:get_env(livery, max_chunk_size, ?MAX_CHUNK_SIZE)
    }.

%% @doc Handle incoming data.
-spec handle_data(binary(), state()) ->
    {ok, state()} |
    {continue, state()} |  %% Send 100 Continue, then call handle_data again
    {response, non_neg_integer(), [{binary(), binary()}], iodata(), state()} |
    {stream, non_neg_integer(), [{binary(), binary()}], fun((fun((iodata() | done | {done, [{binary(), binary()}]}) -> ok)) -> ok), state()} |
    {close, state()} |
    {error, term(), state()}.
handle_data(Data, #h1_state{buffer = Buffer, body_state = BodyState,
                           continue_sent = ContinueSent, body_remaining = BodyRemaining} = State) ->
    NewBuffer = <<Buffer/binary, Data/binary>>,
    NewState = State#h1_state{buffer = NewBuffer},
    case BodyState of
        {chunked, _, _} when ContinueSent ->
            %% Continue reading chunked body after 100 Continue was sent
            handle_chunked_body(NewState);
        {chunked, _, _} ->
            %% Continue reading chunked body
            handle_chunked_body(NewState);
        {chunked_trailers, _} ->
            %% Continue reading trailers
            handle_chunked_trailers(NewState);
        undefined when is_integer(BodyRemaining), ContinueSent ->
            %% Resume body reading after 100 Continue was sent
            handle_with_body(BodyRemaining, NewState);
        undefined ->
            %% Normal request parsing
            parse_and_handle(NewState)
    end.

%% @doc Send a response (for use by connection process).
-spec send_response(gen_tcp:socket() | ssl:sslsocket(), non_neg_integer(),
                    [{binary(), binary()}], iodata(), state()) ->
    {ok, state()} | {close, state()}.
send_response(Socket, Status, Headers, Body, State) ->
    Req = State#h1_state.req,
    Version = case Req of
        undefined -> {1, 1};
        _ -> Req#livery_req.version
    end,

    %% Add connection header if needed
    AllHeaders = add_connection_header(Headers, State),
    Response = livery_resp:build(Status, AllHeaders, Body, Version),

    case send_data(Socket, Response) of
        ok ->
            case State#h1_state.keepalive of
                true ->
                    %% Ready for next request - reset all request-specific state
                    NewState = State#h1_state{
                        req = undefined,
                        handler_state = undefined,
                        request_count = State#h1_state.request_count + 1,
                        body_state = undefined,
                        body_remaining = undefined,
                        expect_continue = false,
                        continue_sent = false
                    },
                    {ok, NewState};
                false ->
                    {close, State}
            end;
        {error, _Reason} ->
            {close, State}
    end.

%% @doc Send a streaming response using chunked transfer encoding.
-spec send_stream(gen_tcp:socket() | ssl:sslsocket(), non_neg_integer(),
                  [{binary(), binary()}],
                  fun((fun((iodata() | done | {done, [{binary(), binary()}]}) -> ok)) -> ok),
                  state()) ->
    {ok, state()} | {close, state()}.
send_stream(Socket, Status, Headers, StreamFun, State) ->
    Req = State#h1_state.req,
    Version = case Req of
        undefined -> {1, 1};
        _ -> Req#livery_req.version
    end,

    %% Add connection header if needed
    AllHeaders = add_connection_header(Headers, State),
    StartResponse = livery_resp:build_chunked_start(Status, AllHeaders, Version),

    case send_data(Socket, StartResponse) of
        ok ->
            %% Create send function for the stream callback
            SendFun = fun
                (done) ->
                    send_data(Socket, livery_resp:encode_last_chunk());
                ({done, Trailers}) ->
                    send_data(Socket, livery_resp:encode_last_chunk(Trailers));
                (Chunk) ->
                    send_data(Socket, livery_resp:encode_chunk(Chunk))
            end,

            %% Call the stream function
            try
                StreamFun(SendFun),
                case State#h1_state.keepalive of
                    true ->
                        %% Reset all request-specific state for next request
                        NewState = State#h1_state{
                            req = undefined,
                            handler_state = undefined,
                            request_count = State#h1_state.request_count + 1,
                            body_state = undefined,
                            body_remaining = undefined,
                            expect_continue = false,
                            continue_sent = false
                        },
                        {ok, NewState};
                    false ->
                        {close, State}
                end
            catch
                _:_ ->
                    {close, State}
            end;
        {error, _Reason} ->
            {close, State}
    end.

%% @doc Close protocol state.
-spec close(state()) -> ok.
close(#h1_state{handler_state = undefined}) ->
    ok;
close(#h1_state{handler = Handler, handler_state = HandlerState}) ->
    try_terminate(Handler, normal, HandlerState),
    ok.

%% Internal functions

parse_and_handle(#h1_state{buffer = Buffer, limits = Limits} = State) ->
    case livery_h1_parse:parse_request(Buffer, Limits) of
        {ok, Method, Path, Qs, Version, Headers, Rest} ->
            %% Validate Host header for HTTP/1.1 (RFC 7230 Section 5.4)
            case validate_host_header(Version, Headers) of
                ok ->
                    parse_and_handle_valid(Method, Path, Qs, Version, Headers, Rest, State);
                {error, Reason} ->
                    {error, Reason, State}
            end;
        {more, _} ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end.

parse_and_handle_valid(Method, Path, Qs, Version, Headers, Rest, State) ->
            %% Build request
            Req = build_request(Method, Path, Qs, Version, Headers, State),

            %% Determine keepalive
            Keepalive = is_keepalive(Version, Headers),
            State1 = State#h1_state{
                buffer = Rest,
                req = Req,
                keepalive = Keepalive
            },

            %% Check for Expect: 100-continue
            ExpectContinue = has_expect_continue(Headers),
            State2 = State1#h1_state{expect_continue = ExpectContinue},

            %% Check for body
            case get_body_info(Headers) of
                {true, Length} when is_integer(Length) ->
                    %% Has body with Content-Length
                    case Length > State2#h1_state.max_body_size of
                        true ->
                            {error, body_too_large, State2};
                        false ->
                            %% If Expect: 100-continue, signal to send 100 first
                            case ExpectContinue andalso not State2#h1_state.continue_sent of
                                true ->
                                    {continue, State2#h1_state{body_remaining = Length}};
                                false ->
                                    handle_with_body(Length, State2)
                            end
                    end;
                {true, chunked} ->
                    %% Chunked transfer encoding (TotalSize starts at 0)
                    case ExpectContinue andalso not State2#h1_state.continue_sent of
                        true ->
                            {continue, State2#h1_state{body_state = {chunked, [], 0}}};
                        false ->
                            handle_chunked_body(State2#h1_state{body_state = {chunked, [], 0}})
                    end;
                {false, _} ->
                    %% No body, handle request directly
                    handle_request(State2);
                {error, Reason} ->
                    %% Invalid Content-Length
                    {error, Reason, State2}
            end.

%% @doc Validate Host header presence per RFC 7230 Section 5.4.
%% HTTP/1.1 requests MUST include a Host header.
%% HTTP/1.0 requests do not require Host header.
validate_host_header({1, 1}, Headers) ->
    case lists:keyfind(<<"host">>, 1, Headers) of
        {_, Host} when byte_size(Host) > 0 ->
            ok;
        {_, <<>>} ->
            %% Empty Host header is invalid
            {error, missing_host_header};
        false ->
            {error, missing_host_header}
    end;
validate_host_header({1, 0}, _Headers) ->
    %% Host header not required for HTTP/1.0
    ok;
validate_host_header(_, _Headers) ->
    %% For other versions, don't enforce
    ok.

build_request(Method, Path, Qs, Version, Headers, #h1_state{handler = Handler, handler_opts = Opts}) ->
    Req = livery_req:new(),
    Req1 = livery_req:set_method(Method, Req),
    Req2 = livery_req:set_path(Path, Req1),
    Req3 = livery_req:set_qs(Qs, Req2),
    Req4 = livery_req:set_version(Version, Req3),
    Req5 = livery_req:set_headers(Headers, Req4),
    livery_req:set_handler(Handler, Opts, Req5).

get_body_info(Headers) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, LengthBin} ->
            try binary_to_integer(LengthBin) of
                0 -> {false, 0};
                Length when Length > 0 -> {true, Length};
                _ -> {error, invalid_content_length}  %% Negative length
            catch
                _:_ -> {error, invalid_content_length}
            end;
        false ->
            case lists:keyfind(<<"transfer-encoding">>, 1, Headers) of
                {_, <<"chunked">>} -> {true, chunked};
                _ -> {false, undefined}
            end
    end.

%% Check if request has Expect: 100-continue header
has_expect_continue(Headers) ->
    case lists:keyfind(<<"expect">>, 1, Headers) of
        {_, Value} ->
            %% Case-insensitive comparison
            string:lowercase(Value) =:= <<"100-continue">>;
        false ->
            false
    end.

%% @doc Mark 100 Continue as sent, allowing body reading to proceed.
%% Call this after sending the 100 Continue response, then call handle_data
%% with empty binary to continue processing.
-spec continue_sent(state()) -> state().
continue_sent(#h1_state{body_remaining = Length} = State) when is_integer(Length) ->
    %% Content-Length body - continue with normal body reading
    State#h1_state{continue_sent = true};
continue_sent(#h1_state{body_state = {chunked, _, _}} = State) ->
    %% Chunked body - continue with chunked reading
    State#h1_state{continue_sent = true};
continue_sent(State) ->
    State#h1_state{continue_sent = true}.

handle_with_body(Length, #h1_state{buffer = Buffer, req = Req0} = State) when byte_size(Buffer) >= Length ->
    <<Body:Length/binary, Rest/binary>> = Buffer,
    %% Decode body if Content-Encoding is present
    Headers = livery_req:headers(Req0),
    ContentEncoding = proplists:get_value(<<"content-encoding">>, Headers, <<>>),
    case decode_body(Body, ContentEncoding) of
        {ok, DecodedBody} ->
            Req = livery_req:set_body(DecodedBody, Req0),
            Req1 = livery_req:set_body_info(true, byte_size(DecodedBody), Req),
            handle_request(State#h1_state{req = Req1, buffer = Rest});
        {error, Reason} ->
            {error, {content_encoding_error, Reason}, State}
    end;
handle_with_body(_Length, State) ->
    %% Need more data
    {ok, State}.

decode_body(Body, <<>>) ->
    {ok, Body};
decode_body(Body, Encoding) ->
    livery_compress:decode(Body, Encoding).

handle_chunked_body(#h1_state{buffer = Buffer, body_state = {chunked, Chunks, TotalSize},
                             max_chunk_size = MaxChunkSize, max_body_size = MaxBodySize} = State) ->
    case livery_h1_parse_erl:parse_chunk(Buffer, MaxChunkSize) of
        {ok, ChunkData, Rest} ->
            ChunkSize = byte_size(ChunkData),
            NewTotalSize = TotalSize + ChunkSize,
            case NewTotalSize > MaxBodySize of
                true ->
                    {error, body_too_large, State};
                false ->
                    %% Got a chunk, continue reading
                    handle_chunked_body(State#h1_state{
                        buffer = Rest,
                        body_state = {chunked, [ChunkData | Chunks], NewTotalSize}
                    })
            end;
        {done, Rest} ->
            %% Final chunk received, now parse trailers
            handle_chunked_trailers(State#h1_state{
                buffer = Rest,
                body_state = {chunked_trailers, Chunks}
            });
        {more, _} ->
            %% Need more data
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end.

handle_chunked_trailers(#h1_state{buffer = Buffer, body_state = {chunked_trailers, Chunks}} = State) ->
    case livery_h1_parse:parse_trailers(Buffer) of
        {ok, Trailers, Rest} ->
            %% Assemble body from chunks (reverse since we prepended)
            Body = iolist_to_binary(lists:reverse(Chunks)),
            Req0 = State#h1_state.req,
            %% Decode body if Content-Encoding is present
            Headers = livery_req:headers(Req0),
            ContentEncoding = proplists:get_value(<<"content-encoding">>, Headers, <<>>),
            case decode_body(Body, ContentEncoding) of
                {ok, DecodedBody} ->
                    BodyLength = byte_size(DecodedBody),
                    Req1 = livery_req:set_body(DecodedBody, Req0),
                    %% Append trailers to headers if any
                    Req2 = case Trailers of
                        [] -> Req1;
                        _ ->
                            CurrentHeaders = livery_req:headers(Req1),
                            livery_req:set_headers(CurrentHeaders ++ Trailers, Req1)
                    end,
                    Req3 = livery_req:set_body_info(true, BodyLength, Req2),
                    handle_request(State#h1_state{
                        req = Req3,
                        buffer = Rest,
                        body_state = undefined
                    });
                {error, Reason} ->
                    {error, {content_encoding_error, Reason}, State}
            end;
        {more, _} ->
            %% Need more data
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end.

handle_request(#h1_state{req = Req, handler = Handler, handler_opts = Opts} = State) ->
    %% Call handler init
    case Handler:init(Req, Opts) of
        {ok, Req1, HandlerState} ->
            %% Call handler handle
            case Handler:handle(Req1, HandlerState) of
                {reply, Status, Headers, Body, NewHandlerState} ->
                    try_terminate(Handler, normal, NewHandlerState),
                    {response, Status, Headers, Body, State#h1_state{handler_state = NewHandlerState}};
                {reply, Status, Headers, NewHandlerState} ->
                    try_terminate(Handler, normal, NewHandlerState),
                    {response, Status, Headers, <<>>, State#h1_state{handler_state = NewHandlerState}};
                {stream, Status, Headers, StreamFun, NewHandlerState} ->
                    %% Streaming response - caller will invoke send_stream
                    {stream, Status, Headers, StreamFun, State#h1_state{handler_state = NewHandlerState}};
                {error, Reason, NewHandlerState} ->
                    try_terminate(Handler, {error, Reason}, NewHandlerState),
                    {error, Reason, State#h1_state{handler_state = NewHandlerState}}
            end;
        {error, Reason} ->
            {error, Reason, State}
    end.

is_keepalive({1, 1}, Headers) ->
    %% HTTP/1.1 defaults to keep-alive unless Connection: close
    case lists:keyfind(<<"connection">>, 1, Headers) of
        {_, Value} ->
            string:lowercase(Value) =/= <<"close">>;
        false ->
            true
    end;
is_keepalive({1, 0}, Headers) ->
    %% HTTP/1.0 defaults to close unless Connection: keep-alive
    case lists:keyfind(<<"connection">>, 1, Headers) of
        {_, Value} ->
            string:lowercase(Value) =:= <<"keep-alive">>;
        false ->
            false
    end;
is_keepalive(_, _) ->
    false.

add_connection_header(Headers, #h1_state{keepalive = false}) ->
    case lists:keyfind(<<"connection">>, 1, Headers) of
        false -> [{<<"connection">>, <<"close">>} | Headers];
        _ -> Headers
    end;
add_connection_header(Headers, #h1_state{keepalive = true, req = Req}) ->
    %% For HTTP/1.0, add keep-alive header
    case Req#livery_req.version of
        {1, 0} ->
            case lists:keyfind(<<"connection">>, 1, Headers) of
                false -> [{<<"connection">>, <<"keep-alive">>} | Headers];
                _ -> Headers
            end;
        _ ->
            Headers
    end.

try_terminate(Handler, Reason, State) ->
    case erlang:function_exported(Handler, terminate, 2) of
        true ->
            try
                Handler:terminate(Reason, State)
            catch
                _:_ -> ok
            end;
        false ->
            ok
    end.

send_data(Socket, Data) when is_port(Socket) ->
    gen_tcp:send(Socket, Data);
send_data(Socket, Data) ->
    ssl:send(Socket, Data).
