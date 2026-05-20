-module(livery_body_limit).
-moduledoc """
Body-size cap middleware.

State: `#{max => MaxBytes}`. When the request body is already
buffered and exceeds the cap, the middleware short-circuits with
`413 Payload Too Large` and skips the handler. Streaming bodies
pass through unchecked here; size enforcement on a streaming
reader lands once the H1 adapter exposes incremental byte counts.
""".
-behaviour(livery_middleware).

-export([call/3]).

-doc "Reject buffered bodies whose `iolist_size/1` exceeds `max`.".
-spec call(livery_req:req(), livery_middleware:next(),
           #{max := non_neg_integer()}) -> livery_resp:resp().
call(Req, Next, #{max := Max}) when is_integer(Max), Max >= 0 ->
    case livery_req:body(Req) of
        {buffered, IoData} ->
            case iolist_size(IoData) of
                Size when Size > Max ->
                    livery_resp:text(413, <<"payload too large">>);
                _ ->
                    Next(Req)
            end;
        _ ->
            Next(Req)
    end.
