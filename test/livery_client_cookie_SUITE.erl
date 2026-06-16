%% @doc Drives the cookie jar layer against a real loopback Livery server
%% (real hackney over the loopback, no external network): a handler sets
%% cookies, a later request through the same jar carries them back.
-module(livery_client_cookie_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    set_then_echo/1,
    path_scoping/1,
    multiple_cookies/1,
    deletion/1,
    host_only_isolation/1,
    no_prior_cookies/1
]).

all() ->
    [
        set_then_echo,
        path_scoping,
        multiple_cookies,
        deletion,
        host_only_isolation,
        no_prior_cookies
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, _} = application:ensure_all_started(hackney),
    Router = livery_router:compile([
        {<<"GET">>, <<"/set">>, fun handle_set/1},
        {<<"GET">>, <<"/echo">>, fun handle_echo/1},
        {<<"GET">>, <<"/set-foo">>, fun handle_set_foo/1},
        {<<"GET">>, <<"/foo/echo">>, fun handle_echo/1},
        {<<"GET">>, <<"/bar/echo">>, fun handle_echo/1},
        {<<"GET">>, <<"/set-multi">>, fun handle_set_multi/1},
        {<<"GET">>, <<"/del">>, fun handle_del/1}
    ]),
    {ok, Pid} = livery:start_service(#{http => #{port => 0}, router => Router}),
    true = unlink(Pid),
    Port = maps:get(h1, livery:which_listeners(Pid)),
    Base = iolist_to_binary([<<"http://127.0.0.1:">>, integer_to_binary(Port)]),
    [{service, Pid}, {port, Port}, {base, Base} | Config].

end_per_suite(Config) ->
    livery:stop_service(?config(service, Config)),
    ok.

%%====================================================================
%% Handlers
%%====================================================================

handle_set(_Req) ->
    livery_resp:text(200, [{<<"Set-Cookie">>, <<"a=1; Path=/">>}], <<"set">>).

handle_set_foo(_Req) ->
    livery_resp:text(200, [{<<"Set-Cookie">>, <<"p=1; Path=/foo">>}], <<"set">>).

handle_del(_Req) ->
    livery_resp:text(200, [{<<"Set-Cookie">>, <<"a=1; Path=/; Max-Age=0">>}], <<"del">>).

handle_set_multi(_Req) ->
    R0 = livery_resp:text(200, <<"set">>),
    R1 = livery_resp:append_header(<<"Set-Cookie">>, <<"m=1; Path=/">>, R0),
    livery_resp:append_header(<<"Set-Cookie">>, <<"n=2; Path=/">>, R1).

handle_echo(Req) ->
    livery_resp:text(200, livery_req:header(<<"cookie">>, Req, <<"none">>)).

%%====================================================================
%% Cases
%%====================================================================

set_then_echo(Config) ->
    C = client(Config),
    {ok, _} = livery_client:get(C, <<"/set">>),
    {ok, Resp} = livery_client:get(C, <<"/echo">>),
    ?assertEqual({full, <<"a=1">>}, livery_client:body(Resp)).

path_scoping(Config) ->
    C = client(Config),
    {ok, _} = livery_client:get(C, <<"/set-foo">>),
    {ok, InScope} = livery_client:get(C, <<"/foo/echo">>),
    ?assertEqual({full, <<"p=1">>}, livery_client:body(InScope)),
    {ok, OutOfScope} = livery_client:get(C, <<"/bar/echo">>),
    ?assertEqual({full, <<"none">>}, livery_client:body(OutOfScope)).

multiple_cookies(Config) ->
    C = client(Config),
    {ok, _} = livery_client:get(C, <<"/set-multi">>),
    {ok, Resp} = livery_client:get(C, <<"/echo">>),
    {full, Body} = livery_client:body(Resp),
    ?assertMatch({_, _}, binary:match(Body, <<"m=1">>)),
    ?assertMatch({_, _}, binary:match(Body, <<"n=2">>)).

deletion(Config) ->
    C = client(Config),
    {ok, _} = livery_client:get(C, <<"/set">>),
    {ok, Before} = livery_client:get(C, <<"/echo">>),
    ?assertEqual({full, <<"a=1">>}, livery_client:body(Before)),
    {ok, _} = livery_client:get(C, <<"/del">>),
    {ok, After} = livery_client:get(C, <<"/echo">>),
    ?assertEqual({full, <<"none">>}, livery_client:body(After)).

%% A host-only cookie set via 127.0.0.1 must not leak to "localhost", even
%% though both reach the same loopback server. Both clients share one jar.
host_only_isolation(Config) ->
    Port = ?config(port, Config),
    Local = iolist_to_binary([<<"http://localhost:">>, integer_to_binary(Port)]),
    Jar = livery_client:cookie_jar(),
    OnIp = livery_client:new(#{base_url => ?config(base, Config), stack => [Jar]}),
    OnName = livery_client:new(#{base_url => Local, stack => [Jar]}),
    {ok, _} = livery_client:get(OnIp, <<"/set">>),
    {ok, Other} = livery_client:get(OnName, <<"/echo">>),
    ?assertEqual({full, <<"none">>}, livery_client:body(Other)),
    {ok, Same} = livery_client:get(OnIp, <<"/echo">>),
    ?assertEqual({full, <<"a=1">>}, livery_client:body(Same)).

no_prior_cookies(Config) ->
    C = client(Config),
    {ok, Resp} = livery_client:get(C, <<"/echo">>),
    ?assertEqual({full, <<"none">>}, livery_client:body(Resp)).

%%====================================================================
%% Helpers
%%====================================================================

client(Config) ->
    livery_client:new(#{
        base_url => ?config(base, Config),
        stack => [livery_client:cookie_jar()]
    }).
