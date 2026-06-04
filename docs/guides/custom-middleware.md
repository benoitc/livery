# How to write a custom middleware

## Problem

You have logic that belongs around your handlers rather than inside
them: checking auth, adding CORS headers, rate limiting, flipping a
feature flag, tweaking the request before it lands. Middleware is
where that lives, and writing your own is straightforward.

## Solution

Implement the `livery_middleware` behaviour. There is just one
callback to write: `call(Req, Next, State) -> Resp`.

```erlang
-module(my_cors).
-behaviour(livery_middleware).
-export([call/3]).

call(Req, Next, #{origins := Allowed} = State) ->
    case livery_req:header(<<"origin">>, Req) of
        undefined ->
            Next(Req);
        Origin ->
            case lists:member(Origin, Allowed) of
                true ->
                    Resp = Next(Req),
                    livery_resp:with_header(
                        <<"access-control-allow-origin">>, Origin, Resp);
                false ->
                    livery_resp:text(403, <<"origin not allowed">>)
            end
    end.
```

Wire it into a stack as `{my_cors, #{origins => [...]}}`.

## Sugar helpers

When the job is small, you do not need a whole module. Reach for the
constructors instead:

```erlang
%% Mutate the request, then continue.
livery_middleware:before(fun(R) ->
    livery_req:set_meta(start, erlang:monotonic_time(), R)
end).

%% Mutate the response on the way out.
livery_middleware:after_response(fun(R) ->
    livery_resp:with_header(<<"X-Server">>, <<"livery">>, R)
end).

%% Catch downstream exceptions and turn them into a response.
livery_middleware:wrap(fun(Class, Reason, _Stack) ->
    livery_resp:text(500,
        iolist_to_binary(io_lib:format("~p: ~p", [Class, Reason])))
end).
```

## Three shapes a middleware can take

Almost everything you write falls into one of these:

1. **Pass-through.** Transform the request or the response, and
   always call `Next`. See `livery_request_id`, `livery_access_log`.
2. **Short-circuit.** Skip `Next` and answer directly. This is how
   auth failures and rate limit hits work.
3. **Wrapper.** Run `Next` inside a `try`/`catch` or a monitor. See
   `livery_middleware:wrap`, `livery_timeout`.

## Storing state on the request

To pass a value from your middleware down to the handler, stash it on
the request with `livery_req:set_meta/3`:

```erlang
call(Req, Next, _State) ->
    {ok, User} = verify(Req),
    Next(livery_req:set_meta(user, User, Req)).
```

The handler reads it back with `livery_req:meta(user, Req)`.

## Ordering

The first entry in the stack is the outermost one. So put auth ahead
of your business logic, and keep request id and error wrappers right
at the top, where they wrap every response.

## Testing

```erlang
denies_when_origin_missing_test() ->
    Cap = livery_test_adapter:run(
        [{my_cors, #{origins => [<<"https://app">>]}}],
        fun (_R) -> livery_resp:text(200, <<>>) end,
        #{headers => [{<<"origin">>, <<"https://evil">>}]}),
    ?assertEqual(403, livery_test_adapter:status(Cap)).
```

## See also

- Tutorial: [Compose a middleware stack](../tutorials/middleware-stack.md)
- Reference: `livery_middleware`
- Reference: `livery_request_id`, `livery_body_limit`, `livery_timeout`, `livery_access_log`
