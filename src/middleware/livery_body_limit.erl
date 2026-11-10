-module(livery_body_limit).
-moduledoc """
Body-size cap middleware.

State: `#{max => MaxBytes}`, a limit for the routes it is on, below the
listener's `max_body`.

- A `Content-Length` above `max` is answered `413 Payload Too Large`
  before the handler runs, without reading the body.
- A streamed body (how the adapters deliver it) is handed to the handler
  through a reader limited to `max` bytes (`livery_body:limit/2`): once
  the handler has read more, `livery_body:read/2` and the readers built
  on it (`read_all`, `livery_ext:read_form/1`, `livery_multipart`)
  return `{error, body_too_large, _}`.
- A body already buffered and larger than `max` is answered `413`.

A handler that never reads the body is not affected, as with the
listener's limit.
""".
-behaviour(livery_middleware).

-export([call/3]).

-doc "Refuse or limit a request body larger than `max`.".
-spec call(
    livery_req:req(),
    livery_middleware:next(),
    #{max := non_neg_integer()}
) -> livery_resp:resp().
call(Req, Next, #{max := Max}) when is_integer(Max), Max >= 0 ->
    case declared_too_large(Req, Max) of
        true ->
            too_large();
        false ->
            case livery_req:body(Req) of
                {buffered, IoData} ->
                    case iolist_size(IoData) > Max of
                        true -> too_large();
                        false -> Next(Req)
                    end;
                {stream, Reader} ->
                    Next(livery_req:set_body({stream, livery_body:limit(Reader, Max)}, Req));
                _ ->
                    Next(Req)
            end
    end.

declared_too_large(Req, Max) ->
    case livery_req:header(<<"content-length">>, Req) of
        undefined ->
            false;
        Value ->
            case string:to_integer(Value) of
                {N, <<>>} when is_integer(N) -> N > Max;
                _ -> false
            end
    end.

too_large() ->
    livery_resp:text(413, <<"payload too large">>).
