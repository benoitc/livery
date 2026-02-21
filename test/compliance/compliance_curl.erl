%% @doc curl runner for HTTP/1.1 compliance testing.
%%
%% Uses curl to test basic HTTP/1.1 functionality:
%% - GET/POST requests
%% - Headers
%% - Chunked transfer encoding
%% - Keep-alive connections
%% - HTTP/1.0 backwards compatibility
-module(compliance_curl).

-export([
    curl_available/0,
    get/2,
    get/3,
    get_http10/2,
    post/3,
    post/4,
    keepalive_test/3,
    raw_request/3
]).

%% @doc Check if curl is available.
-spec curl_available() -> boolean().
curl_available() ->
    case os:find_executable("curl") of
        false -> false;
        _Path -> true
    end.

%% @doc Send a GET request.
-spec get(Port :: inet:port_number(), Path :: string()) ->
    {ok, Status :: integer(), Headers :: [{binary(), binary()}], Body :: binary()} |
    {error, term()}.
get(Port, Path) ->
    get(Port, Path, []).

%% @doc Send a GET request with custom headers.
-spec get(Port :: inet:port_number(), Path :: string(),
          ExtraHeaders :: [{binary(), binary()}]) ->
    {ok, Status :: integer(), Headers :: [{binary(), binary()}], Body :: binary()} |
    {error, term()}.
get(Port, Path, ExtraHeaders) ->
    HeaderArgs = lists:flatmap(fun({Name, Value}) ->
        ["-H", binary_to_list(iolist_to_binary([Name, ": ", Value]))]
    end, ExtraHeaders),

    Args = [
        "-s",  % Silent mode
        "-i",  % Include headers in output
        "--http1.1"  % Force HTTP/1.1
    ] ++ HeaderArgs ++ [
        url(Port, Path)
    ],

    run_curl(Args).

%% @doc Send a GET request using HTTP/1.0.
-spec get_http10(Port :: inet:port_number(), Path :: string()) ->
    {ok, Status :: integer(), Headers :: [{binary(), binary()}], Body :: binary()} |
    {error, term()}.
get_http10(Port, Path) ->
    Args = [
        "-s",
        "-i",
        "--http1.0",  % Force HTTP/1.0
        url(Port, Path)
    ],
    run_curl(Args).

%% @doc Send a POST request.
-spec post(Port :: inet:port_number(), Path :: string(), Body :: binary()) ->
    {ok, Status :: integer(), Headers :: [{binary(), binary()}], Body :: binary()} |
    {error, term()}.
post(Port, Path, Body) ->
    post(Port, Path, Body, [{<<"content-type">>, <<"text/plain">>}]).

%% @doc Send a POST request with custom headers.
-spec post(Port :: inet:port_number(), Path :: string(), Body :: binary(),
           ExtraHeaders :: [{binary(), binary()}]) ->
    {ok, Status :: integer(), Headers :: [{binary(), binary()}], Body :: binary()} |
    {error, term()}.
post(Port, Path, Body, ExtraHeaders) ->
    HeaderArgs = lists:flatmap(fun({Name, Value}) ->
        ["-H", binary_to_list(iolist_to_binary([Name, ": ", Value]))]
    end, ExtraHeaders),

    %% Write body to temp file to avoid shell escaping issues
    TmpFile = "/tmp/livery_curl_body_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = file:write_file(TmpFile, Body),

    Args = [
        "-s",
        "-i",
        "--http1.1",
        "-X", "POST",
        "-d", "@" ++ TmpFile
    ] ++ HeaderArgs ++ [
        url(Port, Path)
    ],

    try
        run_curl(Args)
    after
        file:delete(TmpFile)
    end.

%% @doc Test HTTP keep-alive by making multiple requests on same connection.
-spec keepalive_test(Port :: inet:port_number(), Path :: string(),
                     Count :: pos_integer()) ->
    [Result :: {ok, integer(), [{binary(), binary()}], binary()} | {error, term()}].
keepalive_test(Port, Path, Count) ->
    %% Use curl's ability to make multiple requests on same connection
    Urls = lists:duplicate(Count, url(Port, Path)),

    Args = [
        "-s",
        "-i",
        "--http1.1",
        "-H", "Connection: keep-alive"
    ] ++ Urls,

    %% Run curl and split results
    case run_curl_raw(Args) of
        {ok, Output} ->
            split_responses(Output);
        {error, Reason} ->
            lists:duplicate(Count, {error, Reason})
    end.

%% @doc Send a raw HTTP request.
-spec raw_request(Port :: inet:port_number(), Request :: iodata(),
                  Options :: [atom()]) ->
    {ok, Response :: binary()} | {error, term()}.
raw_request(Port, Request, _Options) ->
    %% Use curl's --data-binary with stdio
    TmpFile = "/tmp/livery_curl_raw_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = file:write_file(TmpFile, Request),

    Args = [
        "-s",
        "--raw",
        "--no-buffer",
        "--connect-to", "::" ++ integer_to_list(Port),
        "http://localhost" ++ TmpFile
    ],

    try
        run_curl_raw(Args)
    after
        file:delete(TmpFile)
    end.

%% Internal functions

url(Port, Path) ->
    "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path.

run_curl(Args) ->
    case run_curl_raw(Args) of
        {ok, Output} ->
            parse_response(Output);
        Error ->
            Error
    end.

run_curl_raw(Args) ->
    CurlPath = case os:find_executable("curl") of
        false -> error(curl_not_found);
        Path -> Path
    end,
    ct:log("Running: curl ~p", [Args]),

    Port = open_port({spawn_executable, CurlPath}, [
        {args, Args},
        stream,
        binary,
        exit_status,
        stderr_to_stdout
    ]),

    collect_curl_output(Port, []).

collect_curl_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_curl_output(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            ct:log("curl failed with status ~p: ~s", [Status, Output]),
            {error, {curl_failed, Status, Output}}
    after 30000 ->
        catch port_close(Port),
        {error, timeout}
    end.

parse_response(Output) ->
    %% Split headers and body at \r\n\r\n
    case binary:split(Output, <<"\r\n\r\n">>) of
        [HeadersPart, Body] ->
            case parse_status_and_headers(HeadersPart) of
                {ok, Status, Headers} ->
                    {ok, Status, Headers, Body};
                Error ->
                    Error
            end;
        [_OnlyHeaders] ->
            %% No body
            case parse_status_and_headers(Output) of
                {ok, Status, Headers} ->
                    {ok, Status, Headers, <<>>};
                Error ->
                    Error
            end
    end.

parse_status_and_headers(HeadersPart) ->
    Lines = binary:split(HeadersPart, <<"\r\n">>, [global]),
    case Lines of
        [StatusLine | HeaderLines] ->
            case parse_status_line(StatusLine) of
                {ok, Status} ->
                    Headers = parse_header_lines(HeaderLines),
                    {ok, Status, Headers};
                Error ->
                    Error
            end;
        [] ->
            {error, empty_response}
    end.

parse_status_line(Line) ->
    %% HTTP/1.1 200 OK
    case binary:split(Line, <<" ">>, [global]) of
        [_Version, StatusBin | _Rest] ->
            try
                {ok, binary_to_integer(StatusBin)}
            catch
                _:_ -> {error, {invalid_status, StatusBin}}
            end;
        _ ->
            {error, {invalid_status_line, Line}}
    end.

parse_header_lines(Lines) ->
    lists:filtermap(fun(Line) ->
        case binary:split(Line, <<": ">>) of
            [Name, Value] ->
                {true, {string:lowercase(Name), Value}};
            _ ->
                false
        end
    end, Lines).

split_responses(Output) ->
    %% Split multiple HTTP responses from keep-alive connection
    %% Each response starts with "HTTP/"
    Parts = binary:split(Output, <<"HTTP/">>, [global]),
    [parse_response(<<"HTTP/", Part/binary>>) || Part <- Parts, Part =/= <<>>].
