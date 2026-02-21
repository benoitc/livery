%% @doc Autobahn|Testsuite runner for WebSocket compliance testing.
%%
%% Autobahn|Testsuite is the industry standard for WebSocket protocol
%% compliance testing, covering RFC 6455 with 500+ test cases.
%%
%% Requires Docker to run the fuzzing client container.
%%
%% Reference: https://github.com/crossbario/autobahn-testsuite
-module(compliance_autobahn).

-export([
    docker_available/0,
    run_cases/2,
    run_all/1,
    parse_report/1
]).

-define(AUTOBAHN_IMAGE, "crossbario/autobahn-testsuite").
-define(REPORT_DIR, "/tmp/livery_autobahn_reports").

%% @doc Check if Docker is available.
-spec docker_available() -> boolean().
docker_available() ->
    case os:find_executable("docker") of
        false -> false;
        _Path ->
            %% Check Docker daemon is running
            case os:cmd("docker info >/dev/null 2>&1 && echo ok") of
                "ok\n" -> true;
                _ -> false
            end
    end.

%% @doc Run specific Autobahn test cases.
%%
%% Cases can be specified as:
%% - "1.*" - All framing basic tests
%% - "2.*" - Ping/pong tests
%% - "5.*" - Fragmentation tests
%% - "6.*" - UTF-8 handling tests
%% - "7.*" - Close handling tests
%% - "9.*" - Performance tests
%% - "12.*,13.*" - Compression tests
-spec run_cases(Port :: inet:port_number(), Cases :: string()) ->
    {ok, Summary :: map()} | {error, term()}.
run_cases(Port, Cases) ->
    Config = generate_config(Port, Cases),
    run_with_config(Port, Config).

%% @doc Run all Autobahn test cases.
-spec run_all(Port :: inet:port_number()) ->
    {ok, Summary :: map()} | {error, term()}.
run_all(Port) ->
    run_cases(Port, "*").

generate_config(Port, Cases) ->
    %% Generate fuzzingclient configuration
    CaseList = case Cases of
        "*" -> [<<"*">>];
        _ ->
            %% Split by comma
            [list_to_binary(C) || C <- string:tokens(Cases, ",")]
    end,

    #{
        <<"outdir">> => <<"/reports">>,
        <<"servers">> => [#{
            <<"agent">> => <<"Livery">>,
            <<"url">> => iolist_to_binary([
                <<"ws://host.docker.internal:">>,
                integer_to_binary(Port),
                <<"/ws">>
            ])
        }],
        <<"cases">> => CaseList,
        <<"exclude-cases">> => [],
        <<"exclude-agent-cases">> => #{}
    }.

run_with_config(Port, Config) ->
    %% Create report directory
    ok = filelib:ensure_dir(?REPORT_DIR ++ "/"),
    file:make_dir(?REPORT_DIR),

    %% Write config file
    ConfigPath = ?REPORT_DIR ++ "/fuzzingclient.json",
    ConfigJson = json:encode(Config),
    ok = file:write_file(ConfigPath, ConfigJson),

    ct:log("Autobahn config: ~s", [ConfigJson]),
    ct:log("Testing against ws://localhost:~p/ws", [Port]),

    %% Run Autobahn container
    Cmd = lists:flatten([
        "docker run --rm ",
        "-v ", ?REPORT_DIR, ":/reports ",
        "--add-host=host.docker.internal:host-gateway ",
        ?AUTOBAHN_IMAGE, " ",
        "wstest -m fuzzingclient -s /reports/fuzzingclient.json"
    ]),

    ct:log("Running: ~s", [Cmd]),

    %% Execute with timeout
    Result = os:cmd(Cmd ++ " 2>&1"),
    ct:log("Autobahn output: ~s", [Result]),

    %% Parse results
    parse_report(?REPORT_DIR ++ "/index.json").

%% @doc Parse Autobahn JSON report.
-spec parse_report(ReportPath :: file:filename()) ->
    {ok, Summary :: map()} | {error, term()}.
parse_report(ReportPath) ->
    case file:read_file(ReportPath) of
        {ok, Json} ->
            try
                Report = json:decode(Json),
                summarize_report(Report)
            catch
                _:Err ->
                    {error, {parse_failed, Err}}
            end;
        {error, enoent} ->
            %% Try HTML report as fallback
            HtmlPath = filename:join(filename:dirname(ReportPath), "index.html"),
            case file:read_file(HtmlPath) of
                {ok, Html} ->
                    parse_html_report(Html);
                _ ->
                    {error, report_not_found}
            end;
        {error, Reason} ->
            {error, {read_failed, Reason}}
    end.

summarize_report(Report) when is_map(Report) ->
    %% Report format: {"Livery": {"1.1.1": {"behavior": "OK", ...}, ...}}
    ServerResults = maps:values(Report),
    Count = fun(Status, Results) ->
        length([1 || R <- maps:values(Results),
                     maps:get(<<"behavior">>, R, <<"UNKNOWN">>) =:= Status])
    end,

    %% Aggregate across all servers (usually just one)
    {Passed, Failed, NonStrict} = lists:foldl(
        fun(Results, {P, F, N}) when is_map(Results) ->
            {P + Count(<<"OK">>, Results),
             F + Count(<<"FAILED">>, Results) + Count(<<"UNCLEAN">>, Results),
             N + Count(<<"NON-STRICT">>, Results) + Count(<<"INFORMATIONAL">>, Results)}
        end,
        {0, 0, 0},
        ServerResults
    ),

    {ok, #{
        passed => Passed,
        failed => Failed,
        non_strict => NonStrict,
        total => Passed + Failed + NonStrict
    }};
summarize_report(_) ->
    {error, invalid_report_format}.

parse_html_report(Html) ->
    %% Simple parsing for pass/fail counts from HTML report
    %% Look for summary table or count badges
    PassedCount = count_matches(Html, <<"behavior_OK">>),
    FailedCount = count_matches(Html, <<"behavior_FAILED">>),
    NonStrictCount = count_matches(Html, <<"behavior_NON-STRICT">>),

    {ok, #{
        passed => PassedCount,
        failed => FailedCount,
        non_strict => NonStrictCount,
        total => PassedCount + FailedCount + NonStrictCount
    }}.

count_matches(Binary, Pattern) ->
    count_matches(Binary, Pattern, 0).

count_matches(Binary, Pattern, Count) ->
    case binary:match(Binary, Pattern) of
        {Pos, Len} ->
            Rest = binary:part(Binary, Pos + Len, byte_size(Binary) - Pos - Len),
            count_matches(Rest, Pattern, Count + 1);
        nomatch ->
            Count
    end.
