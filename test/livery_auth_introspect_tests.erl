-module(livery_auth_introspect_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").

-define(ENDPOINT, <<"https://issuer.example/introspect">>).

%%====================================================================
%% introspect/2
%%====================================================================

active_token_returns_claims_test() ->
    Claims = #{
        <<"active">> => true,
        <<"sub">> => <<"u1">>,
        <<"scope">> => <<"read write">>
    },
    Opts = #{endpoint => ?ENDPOINT, fetch => fetch_json(200, Claims)},
    ?assertEqual({ok, Claims}, livery_auth_introspect:introspect(<<"tok">>, Opts)).

inactive_token_is_rejected_test() ->
    Opts = #{
        endpoint => ?ENDPOINT,
        fetch => fetch_json(200, #{<<"active">> => false})
    },
    ?assertEqual(
        {error, inactive},
        livery_auth_introspect:introspect(<<"tok">>, Opts)
    ).

missing_active_field_is_rejected_test() ->
    Opts = #{
        endpoint => ?ENDPOINT,
        fetch => fetch_json(200, #{<<"sub">> => <<"u1">>})
    },
    ?assertEqual(
        {error, invalid_response},
        livery_auth_introspect:introspect(<<"tok">>, Opts)
    ).

non_200_is_rejected_test() ->
    Opts = #{
        endpoint => ?ENDPOINT,
        fetch => fun(_U, _H, _B) -> {ok, 503, <<>>} end
    },
    ?assertEqual(
        {error, {http_status, 503}},
        livery_auth_introspect:introspect(<<"tok">>, Opts)
    ).

invalid_json_is_rejected_test() ->
    Opts = #{
        endpoint => ?ENDPOINT,
        fetch => fun(_U, _H, _B) -> {ok, 200, <<"not json">>} end
    },
    ?assertEqual(
        {error, invalid_json},
        livery_auth_introspect:introspect(<<"tok">>, Opts)
    ).

transport_error_is_propagated_test() ->
    Opts = #{
        endpoint => ?ENDPOINT,
        fetch => fun(_U, _H, _B) -> {error, econnrefused} end
    },
    ?assertEqual(
        {error, econnrefused},
        livery_auth_introspect:introspect(<<"tok">>, Opts)
    ).

%%====================================================================
%% Request shape
%%====================================================================

posts_token_and_basic_auth_test() ->
    Self = self(),
    Fetch = fun(Url, Headers, Body) ->
        Self ! {req, Url, Headers, Body},
        {ok, 200, <<"{\"active\":true}">>}
    end,
    Opts = #{
        endpoint => ?ENDPOINT,
        client_id => <<"api">>,
        client_secret => <<"sec">>,
        fetch => Fetch
    },
    {ok, _} = livery_auth_introspect:introspect(<<"abc">>, Opts),
    receive
        {req, Url, Headers, Body} ->
            ?assertEqual(?ENDPOINT, Url),
            ?assertEqual(<<"token=abc">>, Body),
            Expected = <<"Basic ", (base64:encode(<<"api:sec">>))/binary>>,
            ?assertEqual(
                Expected,
                proplists:get_value(<<"authorization">>, Headers)
            ),
            ?assertEqual(
                <<"application/x-www-form-urlencoded">>,
                proplists:get_value(<<"content-type">>, Headers)
            )
    after 500 ->
        ?assert(false)
    end.

token_type_hint_is_sent_test() ->
    Self = self(),
    Fetch = fun(_U, _H, Body) ->
        Self ! {body, Body},
        {ok, 200, <<"{\"active\":true}">>}
    end,
    Opts = #{
        endpoint => ?ENDPOINT,
        token_type_hint => <<"access_token">>,
        fetch => Fetch
    },
    {ok, _} = livery_auth_introspect:introspect(<<"abc">>, Opts),
    receive
        {body, Body} ->
            ?assertEqual(<<"token=abc&token_type_hint=access_token">>, Body)
    after 500 ->
        ?assert(false)
    end.

%%====================================================================
%% Middleware
%%====================================================================

handler() ->
    fun(R) ->
        case livery_ext:user(R) of
            undefined -> livery_resp:text(200, <<"anon">>);
            #{<<"sub">> := S} -> livery_resp:text(200, S)
        end
    end.

valid_token_sets_user_meta_test() ->
    Claims = #{<<"active">> => true, <<"sub">> => <<"u9">>},
    Stack = [{livery_auth_introspect, #{endpoint => ?ENDPOINT, fetch => fetch_json(200, Claims)}}],
    Cap = livery_test_adapter:run(
        Stack,
        handler(),
        #{headers => [{<<"authorization">>, <<"Bearer abc">>}]}
    ),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"u9">>, livery_test_adapter:body(Cap)).

inactive_token_returns_401_test() ->
    Stack = [
        {livery_auth_introspect, #{
            endpoint => ?ENDPOINT,
            fetch => fetch_json(200, #{<<"active">> => false})
        }}
    ],
    Cap = livery_test_adapter:run(
        Stack,
        handler(),
        #{headers => [{<<"authorization">>, <<"Bearer abc">>}]}
    ),
    ?assertEqual(401, livery_test_adapter:status(Cap)),
    ?assertEqual(
        <<"Bearer">>,
        livery_test_adapter:header(<<"www-authenticate">>, Cap)
    ).

missing_token_required_returns_401_test() ->
    Stack = [{livery_auth_introspect, #{endpoint => ?ENDPOINT, fetch => fetch_json(200, #{})}}],
    Cap = livery_test_adapter:run(Stack, handler(), #{}),
    ?assertEqual(401, livery_test_adapter:status(Cap)).

missing_token_optional_passes_through_test() ->
    Stack = [
        {livery_auth_introspect, #{
            endpoint => ?ENDPOINT,
            required => false,
            fetch => fetch_json(200, #{})
        }}
    ],
    Cap = livery_test_adapter:run(Stack, handler(), #{}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"anon">>, livery_test_adapter:body(Cap)).

%%====================================================================
%% Helpers
%%====================================================================

fetch_json(Status, Map) ->
    Body = iolist_to_binary(json:encode(Map)),
    fun(_Url, _Headers, _ReqBody) -> {ok, Status, Body} end.
