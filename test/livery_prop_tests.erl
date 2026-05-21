%% @doc Property-based tests (PropEr) for the router and extractors.
-module(livery_prop_tests).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit wrapper so the properties run under `rebar3 eunit'.
%%====================================================================

proper_test_() ->
    Props = [
        prop_static_route_roundtrip(),
        prop_param_route_captures_segment(),
        prop_unknown_method_not_allowed(),
        prop_url_decode_plain_identity(),
        prop_middleware_threads_request()
    ],
    {timeout, 120, [
        ?_assert(proper:quickcheck(P, [{numtests, 200}, {to_file, user}]))
     || P <- Props
    ]}.

%%====================================================================
%% Router properties
%%====================================================================

%% A compiled static route matches its own path and returns its handler.
prop_static_route_roundtrip() ->
    ?FORALL(
        {Segments, Handler},
        {non_empty(list(seg())), term()},
        begin
            Path = <<"/", (join(Segments))/binary>>,
            Router = livery_router:compile([{<<"GET">>, Path, Handler}]),
            case livery_router:match(<<"GET">>, Path, Router) of
                {ok, H, _Bindings, _Meta} -> H =:= Handler;
                _ -> false
            end
        end
    ).

%% A `:param' route captures the supplied segment under the param name.
prop_param_route_captures_segment() ->
    ?FORALL(
        {Name, Value},
        {seg(), seg()},
        begin
            Pattern = <<"/users/:", Name/binary>>,
            Path = <<"/users/", Value/binary>>,
            Router = livery_router:compile([{<<"GET">>, Pattern, h}]),
            case livery_router:match(<<"GET">>, Path, Router) of
                {ok, h, Bindings, _} ->
                    maps:get(Name, Bindings, undefined) =:= Value;
                _ ->
                    false
            end
        end
    ).

%% A path that exists but for a different method yields method_not_allowed.
prop_unknown_method_not_allowed() ->
    ?FORALL(
        Segments,
        non_empty(list(seg())),
        begin
            Path = <<"/", (join(Segments))/binary>>,
            Router = livery_router:compile([{<<"GET">>, Path, h}]),
            case livery_router:match(<<"DELETE">>, Path, Router) of
                {error, {method_not_allowed, Methods}} ->
                    lists:member(<<"GET">>, Methods);
                _ ->
                    false
            end
        end
    ).

%%====================================================================
%% Extractor properties
%%====================================================================

%% A query value with no percent/plus encoding round-trips unchanged.
prop_url_decode_plain_identity() ->
    ?FORALL(
        {K, V},
        {seg(), plain_value()},
        begin
            Raw = <<K/binary, "=", V/binary>>,
            Req = livery_req:new(#{raw_query => Raw}),
            livery_ext:query(K, Req) =:= V
        end
    ).

%%====================================================================
%% Middleware property
%%====================================================================

%% A stack of N request-tagging middlewares all run before the handler,
%% in order, regardless of N.
prop_middleware_threads_request() ->
    ?FORALL(
        N,
        range(0, 12),
        begin
            Stack = [tag_mw(I) || I <- lists:seq(1, N)],
            Handler = fun(R) ->
                Order = livery_req:meta(order, R, []),
                livery_resp:text(200, io_lib:format("~w", [Order]))
            end,
            Resp = livery:dispatch(Stack, Handler, livery_req:new(#{})),
            {full, Body} = livery_resp:body(Resp),
            Got = iolist_to_binary(Body),
            Want = iolist_to_binary(io_lib:format("~w", [lists:seq(1, N)])),
            Got =:= Want
        end
    ).

tag_mw(I) ->
    fun(Req, Next) ->
        Prior = livery_req:meta(order, Req, []),
        Next(livery_req:set_meta(order, Prior ++ [I], Req))
    end.

%%====================================================================
%% Generators
%%====================================================================

%% A non-empty URL path/query segment of unreserved ASCII chars.
seg() ->
    ?LET(Cs, non_empty(list(seg_char())), list_to_binary(Cs)).

seg_char() ->
    oneof(
        lists:seq($a, $z) ++ lists:seq($A, $Z) ++ lists:seq($0, $9) ++
            [$-, $_, $.]
    ).

%% A query value that contains no `%', `+', `&', or `=' (so decoding
%% is the identity).
plain_value() ->
    ?LET(Cs, list(seg_char()), list_to_binary(Cs)).

%%====================================================================
%% Helpers
%%====================================================================

join(Segments) ->
    iolist_to_binary(lists:join(<<"/">>, Segments)).
