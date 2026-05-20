%% @doc Sample middleware module used by livery_middleware_tests.
-module(livery_middleware_tests_sample).

-behaviour(livery_middleware).

-export([call/3]).

call(Req, Next, #{tag := Tag}) ->
    Req1 = livery_req:set_meta(tag, Tag, Req),
    Resp = Next(Req1),
    livery_resp:with_header(<<"X-Tag">>, Tag, Resp).
