-module(livery_static_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

static_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Ctx) ->
        [
            {"serves a file with MIME + ETag", fun() -> serves_file(Ctx) end},
            {"404 for a missing file", fun() -> missing(Ctx) end},
            {"rejects literal traversal", fun() -> traversal_literal(Ctx) end},
            {"rejects encoded traversal", fun() -> traversal_encoded(Ctx) end},
            {"MIME by extension", fun() -> mime(Ctx) end},
            {"conditional GET 304", fun() -> conditional(Ctx) end},
            {"directory index", fun() -> index(Ctx) end},
            {"index disabled", fun() -> index_disabled(Ctx) end},
            {"405 on POST", fun() -> not_allowed(Ctx) end},
            {"HEAD bodyless", fun() -> head(Ctx) end},
            {"Range partial content", fun() -> range(Ctx) end},
            {"Range suffix", fun() -> range_suffix(Ctx) end}
        ]
    end}.

%%====================================================================
%% Fixture
%%====================================================================

setup() ->
    Base = filename:join(
        temp_dir(), "livery_static_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    Root = filename:join(Base, "root"),
    ok = filelib:ensure_path(Root),
    write(Root, "style.css", <<"body{margin:0}">>),
    write(Root, "app.js", <<"console.log(1)">>),
    write(Root, "logo.svg", <<"<svg/>">>),
    write(Root, "data.bin", <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>),
    write(Root, "index.html", <<"<h1>home</h1>">>),
    SecretName = "secret.txt",
    ok = file:write_file(filename:join(Base, SecretName), <<"TOPSECRET">>),
    #{base => Base, root => Root, secret => SecretName}.

cleanup(#{base := Base}) ->
    _ = file:del_dir_r(Base),
    ok.

write(Root, Name, Data) ->
    ok = file:write_file(filename:join(Root, Name), Data).

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.

%%====================================================================
%% Cases
%%====================================================================

serves_file(#{root := Root}) ->
    Cap = run(handler(Root), <<"style.css">>),
    ?assertEqual(200, status(Cap)),
    ?assertEqual(<<"body{margin:0}">>, body(Cap)),
    ?assertEqual(<<"text/css; charset=utf-8">>, hdr(<<"content-type">>, Cap)),
    ?assertMatch(<<"W/\"", _/binary>>, hdr(<<"etag">>, Cap)).

missing(#{root := Root}) ->
    Cap = run(handler(Root), <<"nope.css">>),
    ?assertEqual(404, status(Cap)).

traversal_literal(#{root := Root, secret := Secret}) ->
    Cap = run(handler(Root), <<"../", (list_to_binary(Secret))/binary>>),
    ?assertEqual(404, status(Cap)),
    ?assertNotEqual(<<"TOPSECRET">>, body(Cap)).

traversal_encoded(#{root := Root, secret := Secret}) ->
    Cap = run(handler(Root), <<"..%2f", (list_to_binary(Secret))/binary>>),
    ?assertEqual(404, status(Cap)),
    ?assertNotEqual(<<"TOPSECRET">>, body(Cap)).

mime(#{root := Root}) ->
    H = handler(Root),
    ?assertEqual(
        <<"text/javascript; charset=utf-8">>,
        hdr(<<"content-type">>, run(H, <<"app.js">>))
    ),
    ?assertEqual(<<"image/svg+xml">>, hdr(<<"content-type">>, run(H, <<"logo.svg">>))),
    ?assertEqual(
        <<"application/octet-stream">>,
        hdr(<<"content-type">>, run(H, <<"data.bin">>))
    ).

conditional(#{root := Root}) ->
    H = handler(Root),
    First = run(H, <<"style.css">>),
    ETag = hdr(<<"etag">>, First),
    Cap = run(H, <<"style.css">>, <<"GET">>, [{<<"if-none-match">>, ETag}]),
    ?assertEqual(304, status(Cap)),
    ?assertEqual(<<>>, body(Cap)).

index(#{root := Root}) ->
    Cap = run(handler(Root), <<>>),
    ?assertEqual(200, status(Cap)),
    ?assertEqual(<<"<h1>home</h1>">>, body(Cap)),
    ?assertEqual(<<"text/html; charset=utf-8">>, hdr(<<"content-type">>, Cap)).

index_disabled(#{root := Root}) ->
    Cap = run(livery_static:handler(Root, #{index => false}), <<>>),
    ?assertEqual(404, status(Cap)).

not_allowed(#{root := Root}) ->
    Cap = run(handler(Root), <<"style.css">>, <<"POST">>, []),
    ?assertEqual(405, status(Cap)),
    ?assertEqual(<<"GET, HEAD">>, hdr(<<"allow">>, Cap)).

head(#{root := Root}) ->
    Cap = run(handler(Root), <<"style.css">>, <<"HEAD">>, []),
    ?assertEqual(200, status(Cap)),
    ?assertEqual(<<"14">>, hdr(<<"content-length">>, Cap)),
    ?assertEqual(<<>>, body(Cap)).

range(#{root := Root}) ->
    Cap = run(handler(Root), <<"style.css">>, <<"GET">>, [
        {<<"range">>, <<"bytes=0-3">>}
    ]),
    ?assertEqual(206, status(Cap)),
    ?assertEqual(<<"body">>, body(Cap)),
    ?assert(is_binary(hdr(<<"content-range">>, Cap))).

range_suffix(#{root := Root}) ->
    Cap = run(handler(Root), <<"style.css">>, <<"GET">>, [
        {<<"range">>, <<"bytes=-2">>}
    ]),
    ?assertEqual(206, status(Cap)),
    ?assertEqual(<<"0}">>, body(Cap)).

%%====================================================================
%% Helpers
%%====================================================================

handler(Root) ->
    livery_static:handler(Root).

run(Handler, PathBinding) ->
    run(Handler, PathBinding, <<"GET">>, []).

run(Handler, PathBinding, Method, Headers) ->
    livery_test_adapter:run([], Handler, #{
        method => Method,
        bindings => #{<<"path">> => PathBinding},
        headers => Headers
    }).

status(Cap) -> livery_test_adapter:status(Cap).
body(Cap) -> livery_test_adapter:body(Cap).
hdr(Name, Cap) -> livery_test_adapter:header(Name, Cap).
