%% @doc HTTP/1.x protocol handler.
%%
%% Handles HTTP/1.0 and HTTP/1.1 protocol logic.
-module(livery_h1).

-include("livery.hrl").

-export([
    init/2,
    handle_data/2,
    send_response/5,
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
    limits :: livery_h1_parse:limits()
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
        limits = Limits
    }.

%% @doc Handle incoming data.
-spec handle_data(binary(), state()) ->
    {ok, state()} |
    {response, non_neg_integer(), [{binary(), binary()}], iodata(), state()} |
    {close, state()} |
    {error, term(), state()}.
handle_data(Data, #h1_state{buffer = Buffer} = State) ->
    NewBuffer = <<Buffer/binary, Data/binary>>,
    parse_and_handle(State#h1_state{buffer = NewBuffer}).

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
                    %% Ready for next request
                    NewState = State#h1_state{
                        req = undefined,
                        handler_state = undefined,
                        request_count = State#h1_state.request_count + 1
                    },
                    {ok, NewState};
                false ->
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
            %% Build request
            Req = build_request(Method, Path, Qs, Version, Headers, State),

            %% Determine keepalive
            Keepalive = is_keepalive(Version, Headers),
            State1 = State#h1_state{
                buffer = Rest,
                req = Req,
                keepalive = Keepalive
            },

            %% Check for body
            case get_body_info(Headers) of
                {true, Length} when is_integer(Length) ->
                    %% Has body, need to read it
                    handle_with_body(Length, State1);
                {true, chunked} ->
                    %% Chunked encoding - not implemented in Phase 1
                    {error, chunked_not_implemented, State1};
                {false, _} ->
                    %% No body, handle request directly
                    handle_request(State1)
            end;
        {more, _} ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end.

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
                Length -> {true, Length}
            catch
                _:_ -> {false, undefined}
            end;
        false ->
            case lists:keyfind(<<"transfer-encoding">>, 1, Headers) of
                {_, <<"chunked">>} -> {true, chunked};
                _ -> {false, undefined}
            end
    end.

handle_with_body(Length, #h1_state{buffer = Buffer} = State) when byte_size(Buffer) >= Length ->
    <<Body:Length/binary, Rest/binary>> = Buffer,
    Req = livery_req:set_body(Body, State#h1_state.req),
    Req1 = livery_req:set_body_info(true, Length, Req),
    handle_request(State#h1_state{req = Req1, buffer = Rest});
handle_with_body(_Length, State) ->
    %% Need more data
    {ok, State}.

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
