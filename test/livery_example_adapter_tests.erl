%% @doc Drives the example custom adapter end to end, so the tutorial's
%% "write your own adapter" code stays correct as the framework moves.
-module(livery_example_adapter_tests).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(livery),
    livery_example_adapter:start().

cleanup(L) ->
    livery_example_adapter:stop(L).

adapter_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(L) ->
        [
            ?_test(returns_handler_response(L)),
            ?_test(reads_request_body(L)),
            ?_test(runs_middleware_stack(L))
        ]
    end}.

returns_handler_response(L) ->
    Handler = fun(_Req) -> livery_resp:text(200, <<"hi">>) end,
    Cap = livery_example_adapter:request(L, [], Handler, #{}),
    ?assertEqual(200, livery_example_adapter:status(Cap)),
    ?assertEqual(<<"hi">>, livery_example_adapter:body(Cap)).

%% Feeding `body_bin' proves the worker reads the body over the
%% {livery_body, Ref, _} protocol the adapter speaks.
reads_request_body(L) ->
    Handler = fun(Req) ->
        {stream, Reader} = livery_req:body(Req),
        {ok, Bin, _} = livery_body:read_all(Reader),
        livery_resp:text(200, Bin)
    end,
    Cap = livery_example_adapter:request(
        L, [], Handler, #{method => <<"POST">>, body_bin => <<"echo me">>}
    ),
    ?assertEqual(<<"echo me">>, livery_example_adapter:body(Cap)).

runs_middleware_stack(L) ->
    Mw = fun(Req, Next) ->
        livery_resp:with_header(<<"x-mw">>, <<"1">>, Next(Req))
    end,
    Handler = fun(_Req) -> livery_resp:text(200, <<"ok">>) end,
    Cap = livery_example_adapter:request(L, [Mw], Handler, #{}),
    ?assertEqual(<<"1">>, livery_example_adapter:header(<<"x-mw">>, Cap)).
