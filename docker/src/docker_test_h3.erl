-module(docker_test_h3).

-export([run_tests/0, run_tests/2]).

%% Run HTTP/3 tests using hackney
run_tests() ->
    run_tests("localhost", 9443).

run_tests(Host, Port) ->
    io:format("~n=== HTTP/3 Tests (hackney) ===~n~n"),

    BaseUrl = "https://" ++ Host ++ ":" ++ integer_to_list(Port),
    Options = [
        {ssl_options, [{verify, verify_none}]},
        {protocols, [http3]}
    ],

    Results = [
        run_test("GET /", fun() -> test_hello(BaseUrl, Options) end),
        run_test("GET /greet/Docker", fun() -> test_greet(BaseUrl, Options) end),
        run_test("GET /stream", fun() -> test_stream(BaseUrl, Options) end),
        run_test("GET /sse", fun() -> test_sse(BaseUrl, Options) end),
        run_test("GET /stream-with-trailers", fun() -> test_trailers(BaseUrl, Options) end),
        run_test("GET /large (1MB)", fun() -> test_large(BaseUrl, Options) end)
    ],

    Passed = length([R || R <- Results, R =:= passed]),
    Failed = length([R || R <- Results, R =:= failed]),

    io:format("~n=== Results: ~B passed, ~B failed ===~n~n", [Passed, Failed]),

    case Failed of
        0 -> ok;
        _ -> error
    end.

run_test(Name, TestFun) ->
    try
        case TestFun() of
            ok ->
                io:format("  \e[32m✓\e[0m ~s~n", [Name]),
                passed;
            {error, Reason} ->
                io:format("  \e[31m✗\e[0m ~s: ~p~n", [Name, Reason]),
                failed
        end
    catch
        Class:Error:Stack ->
            io:format("  \e[31m✗\e[0m ~s: ~p:~p~n  ~p~n", [Name, Class, Error, Stack]),
            failed
    end.

test_hello(BaseUrl, Options) ->
    Url = BaseUrl ++ "/",
    case hackney:request(get, Url, [], <<>>, Options) of
        {ok, 200, _Headers, ClientRef} ->
            {ok, Body} = hackney:body(ClientRef),
            case Body of
                <<"Hello, World!">> -> ok;
                Other -> {error, {unexpected_body, Other}}
            end;
        {ok, Status, _, _} ->
            {error, {unexpected_status, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

test_greet(BaseUrl, Options) ->
    Url = BaseUrl ++ "/greet/Docker",
    case hackney:request(get, Url, [], <<>>, Options) of
        {ok, 200, _Headers, ClientRef} ->
            {ok, Body} = hackney:body(ClientRef),
            case Body of
                <<"Hello, Docker!">> -> ok;
                Other -> {error, {unexpected_body, Other}}
            end;
        {ok, Status, _, _} ->
            {error, {unexpected_status, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

test_stream(BaseUrl, Options) ->
    Url = BaseUrl ++ "/stream",
    case hackney:request(get, Url, [], <<>>, Options) of
        {ok, 200, _Headers, ClientRef} ->
            {ok, Body} = hackney:body(ClientRef),
            case Body of
                <<"chunk1chunk2chunk3">> -> ok;
                Other -> {error, {unexpected_body, Other}}
            end;
        {ok, Status, _, _} ->
            {error, {unexpected_status, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

test_sse(BaseUrl, Options) ->
    Url = BaseUrl ++ "/sse",
    case hackney:request(get, Url, [], <<>>, Options) of
        {ok, 200, _Headers, ClientRef} ->
            {ok, Body} = hackney:body(ClientRef),
            case binary:match(Body, <<"event: message">>) of
                nomatch -> {error, {missing_sse_event, Body}};
                _ -> ok
            end;
        {ok, Status, _, _} ->
            {error, {unexpected_status, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

test_trailers(BaseUrl, Options) ->
    Url = BaseUrl ++ "/stream-with-trailers",
    case hackney:request(get, Url, [], <<>>, Options) of
        {ok, 200, _Headers, ClientRef} ->
            {ok, Body} = hackney:body(ClientRef),
            case Body of
                <<"data">> -> ok;
                Other -> {error, {unexpected_body, Other}}
            end;
        {ok, Status, _, _} ->
            {error, {unexpected_status, Status}};
        {error, Reason} ->
            {error, Reason}
    end.

test_large(BaseUrl, Options) ->
    Url = BaseUrl ++ "/large",
    case hackney:request(get, Url, [], <<>>, Options) of
        {ok, 200, _Headers, ClientRef} ->
            {ok, Body} = hackney:body(ClientRef),
            ExpectedSize = 1024 * 1024,
            case byte_size(Body) of
                ExpectedSize -> ok;
                Other -> {error, {unexpected_size, Other, expected, ExpectedSize}}
            end;
        {ok, Status, _, _} ->
            {error, {unexpected_status, Status}};
        {error, Reason} ->
            {error, Reason}
    end.
