-module(livery_alt_svc).
-moduledoc """
Alt-Svc advertising middleware.

State: `#{value => Value}`. Injects `Alt-Svc: Value` on responses
served over H1 and H2 so clients can race up to H3 on the next
request. Responses already served over H3 are passed through
unchanged.

Wired automatically by `livery:start_service/1` when the service
config sets `alt_svc => advertise` and an `http3` listener is
configured.
""".
-behaviour(livery_middleware).

-export([call/3]).

-spec call(
    livery_req:req(),
    livery_middleware:next(),
    #{value := binary()}
) -> livery_resp:resp().
call(Req, Next, #{value := Value}) when is_binary(Value) ->
    Resp = Next(Req),
    case livery_req:protocol(Req) of
        h3 -> Resp;
        _ -> livery_resp:with_header(<<"alt-svc">>, Value, Resp)
    end.
