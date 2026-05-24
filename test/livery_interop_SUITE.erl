%% @doc External-client interop SUITE for response compression.
%%
%% Proves the gzip output is standards-compliant by decoding it with
%% tools that are NOT the OTP `zlib' encoder: the system `curl' (its own
%% zlib, via `--compressed') and the system `gzip(1)' CLI. Skips cleanly
%% when curl or gzip are not on the PATH.
-module(livery_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    h1_curl_auto_decompress/1,
    h1_os_gzip_decode/1,
    h1_identity_without_accept_encoding/1
]).

-define(BODY,
    <<"{\"message\":\"interop body proving any client can decode gzip\",\"items\":[1,2,3,4,5,6,7,8,9,10]}">>
).

%% H2/H3 gzip is proven by the parity SUITE (real h2/h3 clients decode
%% the body); the bytes are identical across adapters, so this
%% external-tool check on H1 establishes standards compliance for all.
all() ->
    [
        h1_curl_auto_decompress,
        h1_os_gzip_decode,
        h1_identity_without_accept_encoding
    ].

init_per_suite(Config) ->
    case {os:find_executable("curl"), os:find_executable("gzip")} of
        {false, _} ->
            {skip, "curl not on PATH"};
        {_, false} ->
            {skip, "gzip not on PATH"};
        {Curl, Gzip} ->
            {ok, _} = application:ensure_all_started(livery),
            {ok, _} = application:ensure_all_started(h1),
            [{curl, Curl}, {gzip, Gzip} | Config]
    end.

end_per_suite(_Config) ->
    _ = application:stop(h1),
    _ = application:stop(livery),
    ok.

%% Start the H1 listener in the test-case process so it stays reachable
%% for the duration of the case (a listener tied to init_per_suite is
%% torn down before the case runs).
init_per_testcase(_TC, Config) ->
    {ok, Listener} = livery_h1:start(#{
        port => 0,
        stack => [{livery_compress, #{min_size => 0}}],
        handler => fun(_R) -> livery_resp:json(200, ?BODY) end
    }),
    Port = h1:server_port(Listener),
    [{listener, Listener}, {port, Port} | Config].

end_per_testcase(_TC, Config) ->
    livery_h1:stop(?config(listener, Config)),
    ok.

%%====================================================================
%% H1 cases
%%====================================================================

h1_curl_auto_decompress(Config) ->
    %% curl sends Accept-Encoding and auto-decompresses with its own zlib.
    Url = url(Config),
    Headers = sh(Config, [curl(Config), "-sS --max-time 15 -D - -o /dev/null --compressed", Url]),
    ?assert(header_has(Headers, "content-encoding", "gzip")),
    ?assert(header_has(Headers, "vary", "accept-encoding")),
    Body = sh(Config, [curl(Config), "-sS --max-time 15 --compressed", Url]),
    ?assertEqual(?BODY, Body).

h1_os_gzip_decode(Config) ->
    %% Decode with the OS gzip(1), a different implementation than OTP.
    Url = url(Config),
    Cmd = [
        curl(Config),
        "-sS --max-time 15 -H 'Accept-Encoding: gzip'",
        Url,
        "|",
        gzip(Config),
        "-dc"
    ],
    ?assertEqual(?BODY, sh(Config, Cmd)).

h1_identity_without_accept_encoding(Config) ->
    %% No Accept-Encoding: a client that cannot decode gets identity.
    Url = url(Config),
    Headers = sh(Config, [curl(Config), "-sS --max-time 15 -D - -o /dev/null", Url]),
    ?assertNot(header_present(Headers, "content-encoding")),
    Body = sh(Config, [curl(Config), "-sS", Url]),
    ?assertEqual(?BODY, Body).

%%====================================================================
%% Helpers
%%====================================================================

curl(Config) -> ?config(curl, Config).
gzip(Config) -> ?config(gzip, Config).

url(Config) ->
    "http://127.0.0.1:" ++ integer_to_list(?config(port, Config)) ++ "/".

sh(_Config, Parts) ->
    Cmd = lists:flatten(lists:join(" ", Parts)),
    iolist_to_binary(os:cmd(Cmd)).

%% Header dump from `curl -D -' is CRLF-delimited "Name: Value" lines.
header_present(Dump, NameLower) ->
    lists:any(
        fun(Line) -> is_header_line(Line, NameLower) end,
        header_lines(Dump)
    ).

header_has(Dump, NameLower, ValueLower) ->
    lists:any(
        fun(Line) ->
            is_header_line(Line, NameLower) andalso
                string:find(string:lowercase(Line), ValueLower) =/= nomatch
        end,
        header_lines(Dump)
    ).

header_lines(Dump) ->
    string:split(binary_to_list(Dump), "\n", all).

is_header_line(Line, NameLower) ->
    Lower = string:lowercase(string:trim(Line)),
    string:prefix(Lower, NameLower ++ ":") =/= nomatch.
