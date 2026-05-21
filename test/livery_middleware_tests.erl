-module(livery_middleware_tests).
-compile([export_all, nowarn_export_all]).

-include_lib("eunit/include/eunit.hrl").
-include("livery.hrl").

handler_only_test() ->
    Req = req(),
    Resp = livery_middleware:run(
        [],
        fun(_R) -> livery_resp:text(200, <<"ok">>) end,
        Req
    ),
    ?assertEqual(200, livery_resp:status(Resp)).

mfa_handler_test() ->
    Req = req(),
    Resp = livery_middleware:run([], {?MODULE, handle_ok}, Req),
    ?assertEqual(200, livery_resp:status(Resp)).

handle_ok(_Req) ->
    livery_resp:text(200, <<"ok">>).

before_transforms_request_test() ->
    Stack = [
        livery_middleware:before(fun(R) ->
            livery_req:set_meta(marker, yes, R)
        end)
    ],
    Handler = fun(R) ->
        case livery_req:meta(marker, R) of
            yes -> livery_resp:text(200, <<"tagged">>);
            _ -> livery_resp:text(500, <<"missing">>)
        end
    end,
    Resp = livery_middleware:run(Stack, Handler, req()),
    ?assertEqual(200, livery_resp:status(Resp)).

after_response_transforms_response_test() ->
    Stack = [
        livery_middleware:after_response(fun(Resp) ->
            livery_resp:with_header(<<"X-After">>, <<"1">>, Resp)
        end)
    ],
    Handler = fun(_) -> livery_resp:text(200, <<"ok">>) end,
    Resp = livery_middleware:run(Stack, Handler, req()),
    ?assertEqual(<<"1">>, header(Resp, <<"x-after">>)).

order_is_outside_in_for_request_test() ->
    %% The first middleware in the list is the outermost; it sees the
    %% request first and the response last.
    Stack = [
        fun(R, Next) ->
            R1 = livery_req:set_meta(order, [a], R),
            Next(R1)
        end,
        fun(R, Next) ->
            Prior = livery_req:meta(order, R, []),
            R1 = livery_req:set_meta(order, Prior ++ [b], R),
            Next(R1)
        end
    ],
    Handler = fun(R) ->
        Order = livery_req:meta(order, R),
        livery_resp:text(200, io_lib:format("~p", [Order]))
    end,
    Resp = livery_middleware:run(Stack, Handler, req()),
    ?assertEqual(<<"[a,b]">>, iolist_to_binary(body(Resp))).

short_circuit_test() ->
    Stack = [
        fun(_Req, _Next) -> livery_resp:text(401, <<"nope">>) end,
        fun(_, _) -> error(must_not_be_called) end
    ],
    Resp = livery_middleware:run(
        Stack,
        fun(_) -> error(must_not_be_called) end,
        req()
    ),
    ?assertEqual(401, livery_resp:status(Resp)).

module_entry_test() ->
    Stack = [{livery_middleware_tests_sample, #{tag => <<"t">>}}],
    Handler = fun(R) ->
        livery_resp:text(200, livery_req:meta(tag, R))
    end,
    Resp = livery_middleware:run(Stack, Handler, req()),
    ?assertEqual(<<"t">>, iolist_to_binary(body(Resp))),
    ?assertEqual(<<"t">>, header(Resp, <<"x-tag">>)).

wrap_maps_exception_to_response_test() ->
    Stack = [
        livery_middleware:wrap(fun(Class, _R, _S) ->
            livery_resp:text(
                500,
                iolist_to_binary(io_lib:format("caught-~s", [Class]))
            )
        end)
    ],
    Handler = fun(_) -> error(boom) end,
    Resp = livery_middleware:run(Stack, Handler, req()),
    ?assertEqual(500, livery_resp:status(Resp)),
    ?assertEqual(<<"caught-error">>, iolist_to_binary(body(Resp))).

%%====================================================================
%% Helpers
%%====================================================================

req() ->
    livery_req:new(#{
        protocol => h1, method => <<"GET">>, path => <<"/">>
    }).

header(Resp, Name) ->
    case lists:keyfind(Name, 1, livery_resp:headers(Resp)) of
        {_, V} -> V;
        false -> undefined
    end.

body(Resp) ->
    case livery_resp:body(Resp) of
        {full, B} -> B;
        Other -> Other
    end.
