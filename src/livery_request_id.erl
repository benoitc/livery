-module(livery_request_id).
-moduledoc """
Request-ID middleware.

Generates a fresh per-request identifier or honors an existing
`X-Request-ID` header. The id is stored on the request value
(`livery_req:req_id/1`) and echoed on the response so that
clients and downstream services can correlate.

Identifiers are 32-character lowercase hex strings derived from
`crypto:strong_rand_bytes/1`.
""".
-behaviour(livery_middleware).

-export([call/3]).

-define(HEADER, <<"x-request-id">>).

-doc "Run the middleware. State is unused.".
-spec call(livery_req:req(), livery_middleware:next(), term()) ->
    livery_resp:resp().
call(Req, Next, _State) ->
    Id =
        case livery_req:header(?HEADER, Req) of
            undefined -> generate();
            Existing -> Existing
        end,
    Req1 = livery_req:set_req_id(Id, Req),
    Resp = Next(Req1),
    livery_resp:with_header(?HEADER, Id, Resp).

-spec generate() -> binary().
generate() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).
