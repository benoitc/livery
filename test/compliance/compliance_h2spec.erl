%% @doc h2spec runner for HTTP/2 compliance testing.
%%
%% h2spec is a conformance testing tool for HTTP/2 implementations.
%% It tests RFC 7540 (HTTP/2) and RFC 7541 (HPACK) compliance.
%%
%% Reference: https://github.com/summerwind/h2spec
-module(compliance_h2spec).

-export([
    find_h2spec/1,
    run/3,
    run/4,
    parse_output/1,
    available/1
]).

%% @doc Check if h2spec is available.
-spec available(ProjectRoot :: file:filename()) -> boolean().
available(ProjectRoot) ->
    case find_h2spec(ProjectRoot) of
        {ok, _Path} -> true;
        error -> false
    end.

%% @doc Find h2spec binary.
-spec find_h2spec(ProjectRoot :: file:filename()) -> {ok, file:filename()} | error.
find_h2spec(ProjectRoot) ->
    H2specPath = filename:join([ProjectRoot, "priv", "tools", "h2spec"]),
    case filelib:is_regular(H2specPath) of
        true -> {ok, H2specPath};
        false ->
            %% Try system PATH
            case os:find_executable("h2spec") of
                false -> error;
                Path -> {ok, Path}
            end
    end.

%% @doc Run h2spec tests against a server.
%%
%% Section can be:
%% - "generic" - Generic HTTP/2 tests
%% - "http2" - HTTP/2 frame tests
%% - "hpack" - HPACK compression tests
%% - or a specific section like "http2/6.1" for DATA frames
-spec run(ProjectRoot :: file:filename(),
          Port :: inet:port_number(),
          Section :: string()) ->
    {ok, Passed :: non_neg_integer(), Total :: non_neg_integer(), Output :: binary()} |
    {error, term()}.
run(ProjectRoot, Port, Section) ->
    run(ProjectRoot, Port, Section, []).

%% @doc Run h2spec tests with additional options.
-spec run(ProjectRoot :: file:filename(),
          Port :: inet:port_number(),
          Section :: string(),
          Options :: [atom() | {atom(), term()}]) ->
    {ok, Passed :: non_neg_integer(), Total :: non_neg_integer(), Output :: binary()} |
    {error, term()}.
run(ProjectRoot, Port, Section, Options) ->
    case find_h2spec(ProjectRoot) of
        {ok, H2specPath} ->
            run_h2spec(H2specPath, Port, Section, Options);
        error ->
            {error, h2spec_not_found}
    end.

run_h2spec(H2specPath, Port, Section, Options) ->
    %% Build command arguments
    Host = proplists:get_value(host, Options, "127.0.0.1"),
    Timeout = proplists:get_value(timeout, Options, 5),
    Strict = proplists:get_value(strict, Options, true),
    Verbose = proplists:get_value(verbose, Options, false),

    Args = [
        "-h", Host,
        "-p", integer_to_list(Port),
        "-t", "-k",  % TLS with insecure skip verify
        "--timeout", integer_to_list(Timeout),
        "-j"  % JSON output for easier parsing
    ] ++
    case Strict of true -> ["--strict"]; false -> [] end ++
    case Verbose of true -> ["-v"]; false -> [] end ++
    [Section],

    Cmd = lists:flatten([H2specPath, " ", string:join(Args, " ")]),
    ct:log("Running: ~s", [Cmd]),

    %% Run h2spec and capture output
    Port0 = open_port({spawn, Cmd}, [
        stream,
        binary,
        exit_status,
        stderr_to_stdout,
        {line, 16384}
    ]),

    collect_output(Port0, []).

collect_output(Port, Acc) ->
    receive
        {Port, {data, {eol, Line}}} ->
            collect_output(Port, [Line, <<"\n">> | Acc]);
        {Port, {data, {noeol, Line}}} ->
            collect_output(Port, [Line | Acc]);
        {Port, {exit_status, _Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            parse_output(Output)
    after 60000 ->
        catch port_close(Port),
        {error, timeout}
    end.

%% @doc Parse h2spec output to extract test results.
-spec parse_output(binary()) ->
    {ok, Passed :: non_neg_integer(), Total :: non_neg_integer(), Output :: binary()} |
    {error, term()}.
parse_output(Output) ->
    %% h2spec JSON output format:
    %% {"duration":...,"passed":X,"skipped":Y,"failed":Z,...}
    %% Try to extract from JSON first
    case extract_json_stats(Output) of
        {ok, Passed, Total} ->
            {ok, Passed, Total, Output};
        error ->
            %% Fallback to text parsing
            %% Look for "X tests, Y passed, Z skipped, W failed"
            case extract_text_stats(Output) of
                {ok, Passed, Total} ->
                    {ok, Passed, Total, Output};
                error ->
                    {error, {parse_failed, Output}}
            end
    end.

extract_json_stats(Output) ->
    %% Look for JSON line with stats
    Lines = binary:split(Output, <<"\n">>, [global]),
    find_json_stats(Lines).

find_json_stats([]) ->
    error;
find_json_stats([Line | Rest]) ->
    case binary:match(Line, <<"\"passed\":">>)  of
        nomatch ->
            find_json_stats(Rest);
        _ ->
            try
                %% Very simple JSON parsing for our specific format
                Passed = extract_json_int(Line, <<"\"passed\":">>),
                Failed = extract_json_int(Line, <<"\"failed\":">>),
                Skipped = extract_json_int(Line, <<"\"skipped\":">>),
                Total = Passed + Failed + Skipped,
                {ok, Passed, Total}
            catch
                _:_ -> find_json_stats(Rest)
            end
    end.

extract_json_int(Binary, Key) ->
    case binary:match(Binary, Key) of
        {Start, Len} ->
            Rest = binary:part(Binary, Start + Len, byte_size(Binary) - Start - Len),
            %% Extract number until non-digit
            extract_number(Rest, []);
        nomatch ->
            0
    end.

extract_number(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    extract_number(Rest, [C | Acc]);
extract_number(_, Acc) ->
    list_to_integer(lists:reverse(Acc)).

extract_text_stats(Output) ->
    %% Look for "Finished in ... X passed, Y skipped, Z failed"
    case re:run(Output, "([0-9]+) passed.*?([0-9]+) failed",
                [{capture, all_but_first, binary}]) of
        {match, [PassedBin, FailedBin]} ->
            Passed = binary_to_integer(PassedBin),
            Failed = binary_to_integer(FailedBin),
            {ok, Passed, Passed + Failed};
        nomatch ->
            error
    end.
