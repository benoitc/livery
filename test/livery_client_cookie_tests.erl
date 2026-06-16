%% @doc Drives the cookie jar layer directly with a synthetic `Next`, so
%% host, scheme, and path can be set freely without a socket. Pins the
%% RFC 6265 matching/parsing rules the loopback SUITE cannot reach.
-module(livery_client_cookie_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FAR_FUTURE, <<"Tue, 19 Jan 2038 03:14:07 GMT">>).
-define(PAST, <<"Thu, 01 Jan 1970 00:00:00 GMT">>).

%%====================================================================
%% Helpers
%%====================================================================

new_jar() -> new_jar(#{}).

new_jar(Opts) ->
    {livery_client_cookie, State} = livery_client:cookie_jar(Opts),
    State.

req(Url) -> req(Url, []).

req(Url, Headers) -> #{method => get, url => Url, headers => Headers}.

%% Seed the jar with the given Set-Cookie values, as if a response carried
%% them for a request to Url.
set(State, Url, SetCookies) ->
    Next = fun(_Req) ->
        {ok, #{
            status => 200,
            headers => [{<<"set-cookie">>, V} || V <- SetCookies],
            body => {full, <<>>}
        }}
    end,
    {ok, _} = livery_client_cookie:call(req(Url), Next, State),
    ok.

%% The Cookie header the jar would attach to a request to Url.
sent(State, Url) -> sent(State, Url, []).

sent(State, Url, Headers) ->
    Self = self(),
    Next = fun(R) ->
        Self ! {cookie, livery_client:header(<<"cookie">>, R)},
        {ok, #{status => 200, headers => [], body => {full, <<>>}}}
    end,
    {ok, _} = livery_client_cookie:call(req(Url, Headers), Next, State),
    receive
        {cookie, V} -> V
    after 1000 -> error(no_capture)
    end.

count(#{module := M, store := S}) -> length(M:get(S)).

%%====================================================================
%% Cases
%%====================================================================

host_only_isolation_test() ->
    J = new_jar(),
    set(J, <<"http://example.com/">>, [<<"a=1">>]),
    ?assertEqual(<<"a=1">>, sent(J, <<"http://example.com/">>)),
    ?assertEqual(undefined, sent(J, <<"http://other.com/">>)).

domain_subdomain_test() ->
    J = new_jar(),
    set(J, <<"http://example.com/">>, [<<"a=1; Domain=example.com">>]),
    ?assertEqual(<<"a=1">>, sent(J, <<"http://example.com/">>)),
    ?assertEqual(<<"a=1">>, sent(J, <<"http://sub.example.com/">>)),
    ?assertEqual(undefined, sent(J, <<"http://other.com/">>)).

secure_scheme_test() ->
    J = new_jar(),
    set(J, <<"https://h.test/">>, [<<"s=1; Secure">>]),
    ?assertEqual(<<"s=1">>, sent(J, <<"https://h.test/">>)),
    ?assertEqual(undefined, sent(J, <<"http://h.test/">>)).

path_scoping_test() ->
    J = new_jar(),
    set(J, <<"http://h.test/">>, [<<"p=1; Path=/admin">>]),
    ?assertEqual(<<"p=1">>, sent(J, <<"http://h.test/admin">>)),
    ?assertEqual(<<"p=1">>, sent(J, <<"http://h.test/admin/sub">>)),
    ?assertEqual(undefined, sent(J, <<"http://h.test/admins">>)),
    ?assertEqual(undefined, sent(J, <<"http://h.test/other">>)).

max_age_overrides_expires_test() ->
    J = new_jar(),
    set(J, <<"http://h.test/">>, [
        %% Max-Age 0 wins over a far-future Expires: never stored.
        <<"m=1; Max-Age=0; Expires=", ?FAR_FUTURE/binary>>,
        %% Max-Age wins over a past Expires: stored and live.
        <<"n=2; Max-Age=1000; Expires=", ?PAST/binary>>
    ]),
    ?assertEqual(<<"n=2">>, sent(J, <<"http://h.test/">>)).

expires_past_deletes_test() ->
    J = new_jar(),
    set(J, <<"http://h.test/">>, [<<"e=1">>]),
    ?assertEqual(<<"e=1">>, sent(J, <<"http://h.test/">>)),
    set(J, <<"http://h.test/">>, [<<"e=1; Expires=", ?PAST/binary>>]),
    ?assertEqual(undefined, sent(J, <<"http://h.test/">>)).

longest_path_first_test() ->
    J = new_jar(),
    set(J, <<"http://h.test/foo">>, [<<"a=1; Path=/">>, <<"b=2; Path=/foo">>]),
    ?assertEqual(<<"b=2; a=1">>, sent(J, <<"http://h.test/foo/bar">>)).

merge_preserves_caller_cookie_test() ->
    J = new_jar(),
    set(J, <<"http://h.test/">>, [<<"a=1">>]),
    ?assertEqual(
        <<"x=9; a=1">>,
        sent(J, <<"http://h.test/">>, [{<<"Cookie">>, <<"x=9">>}])
    ).

no_cookie_no_header_test() ->
    J = new_jar(),
    ?assertEqual(undefined, sent(J, <<"http://h.test/">>)).

multiple_cookies_test() ->
    J = new_jar(),
    set(J, <<"http://h.test/">>, [<<"a=1">>, <<"b=2">>]),
    Header = sent(J, <<"http://h.test/">>),
    ?assertMatch({_, _}, binary:match(Header, <<"a=1">>)),
    ?assertMatch({_, _}, binary:match(Header, <<"b=2">>)).

replace_same_key_test() ->
    J = new_jar(),
    set(J, <<"http://h.test/">>, [<<"a=1">>]),
    set(J, <<"http://h.test/">>, [<<"a=2">>]),
    ?assertEqual(<<"a=2">>, sent(J, <<"http://h.test/">>)).

eviction_test() ->
    J = new_jar(#{max_cookies => 2}),
    set(J, <<"http://h.test/">>, [<<"a=1">>, <<"b=2">>, <<"c=3">>]),
    ?assertEqual(2, count(J)).

ignore_nameless_test() ->
    J = new_jar(),
    set(J, <<"http://h.test/">>, [<<"=novalue">>, <<"justtext">>]),
    ?assertEqual(undefined, sent(J, <<"http://h.test/">>)).
