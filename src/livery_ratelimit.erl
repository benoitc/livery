-module(livery_ratelimit).
-moduledoc """
Per-key rate-limiting / throttling middleware (token bucket).

Each client (by default identified by its Authorization bearer token) gets
a token bucket: `Capacity` tokens that refill at `RefillPerSec`. A request
consumes one token; when the bucket is empty the request is shed with
`429 Too Many Requests`. A request with no key passes through unlimited.

Build the stack entry with `limiter/2,3` (which allocates an isolated
keyspace):

```erlang
Stack = [
    {livery_ratelimit, livery_ratelimit:limiter(100, 10)}  %% burst 100, 10/s
].
```

"N requests per minute" maps to `limiter(N, N/60)`. Per-key state lives in
the supervised `livery_ratelimit_store` ETS table; the raw key is never
stored (it is SHA-256 hashed). Client IP is not available from the wire
libs, so identify clients by token or a custom `key` fun. Responses carry
`RateLimit-Limit`/`-Remaining`/`-Reset` (and `Retry-After` on a 429)
unless `headers => false`.
""".
-behaviour(livery_middleware).

-export([limiter/2, limiter/3, call/3]).

-export_type([state/0]).

-type key_fun() :: fun((livery_req:req()) -> binary() | undefined).

-type state() :: #{
    name := term(),
    capacity := non_neg_integer(),
    rate := number(),
    key := key_fun(),
    status := 100..599,
    body := iodata(),
    headers := boolean()
}.

-doc "Build a limiter: `Capacity` burst tokens refilling at `RefillPerSec`.".
-spec limiter(non_neg_integer(), number()) -> state().
limiter(Capacity, RefillPerSec) ->
    limiter(Capacity, RefillPerSec, #{}).

-doc """
`limiter/2` with options: `name`, `key` (a `req -> binary | undefined`
fun, default the bearer token), `status` (default 429), `body`, and
`headers` (default `true`).
""".
-spec limiter(non_neg_integer(), number(), map()) -> state().
limiter(Capacity, RefillPerSec, Opts) when
    is_integer(Capacity), Capacity >= 0, is_number(RefillPerSec), RefillPerSec >= 0
->
    #{
        name => maps:get(name, Opts, make_ref()),
        capacity => Capacity,
        rate => RefillPerSec,
        key => maps:get(key, Opts, fun default_key/1),
        status => maps:get(status, Opts, 429),
        body => maps:get(body, Opts, <<"too many requests">>),
        headers => maps:get(headers, Opts, true)
    }.

-doc "Throttle the request by its key, or pass through when keyless.".
-spec call(livery_req:req(), livery_middleware:next(), state()) ->
    livery_resp:resp().
call(Req, Next, #{key := KeyFun} = State) ->
    case KeyFun(Req) of
        undefined -> Next(Req);
        Key when is_binary(Key) -> limit(Key, Req, Next, State)
    end.

-spec default_key(livery_req:req()) -> binary() | undefined.
default_key(Req) ->
    livery_ext:bearer_token(Req).

-spec limit(binary(), livery_req:req(), livery_middleware:next(), state()) ->
    livery_resp:resp().
limit(Key, Req, Next, #{name := Name, capacity := Cap, rate := Rate} = State) ->
    Digest = crypto:hash(sha256, Key),
    Now = erlang:monotonic_time(microsecond),
    case livery_ratelimit_store:check(Name, Digest, Cap, Rate, Now) of
        {allow, Remaining, Reset} ->
            allow_headers(Next(Req), State, Remaining, Reset);
        {deny, RetryAfter} ->
            denied(State, RetryAfter)
    end.

-spec allow_headers(
    livery_resp:resp(), state(), float(), non_neg_integer() | undefined
) -> livery_resp:resp().
allow_headers(Resp, #{headers := false}, _Remaining, _Reset) ->
    Resp;
allow_headers(Resp, #{headers := true, capacity := Cap}, Remaining, Reset) ->
    rl_headers(Resp, Cap, trunc(Remaining), Reset).

-spec denied(state(), non_neg_integer() | undefined) -> livery_resp:resp().
denied(#{headers := false, status := Status, body := Body}, _RetryAfter) ->
    livery_resp:text(Status, Body);
denied(#{headers := true, status := Status, body := Body, capacity := Cap}, RetryAfter) ->
    Resp = rl_headers(livery_resp:text(Status, Body), Cap, 0, undefined),
    maybe_retry_after(Resp, RetryAfter).

-spec rl_headers(
    livery_resp:resp(), non_neg_integer(), non_neg_integer(), non_neg_integer() | undefined
) -> livery_resp:resp().
rl_headers(Resp, Cap, Remaining, Reset) ->
    R1 = livery_resp:with_header(<<"ratelimit-limit">>, integer_to_binary(Cap), Resp),
    R2 = livery_resp:with_header(
        <<"ratelimit-remaining">>, integer_to_binary(Remaining), R1
    ),
    maybe_reset(R2, Reset).

-spec maybe_reset(livery_resp:resp(), non_neg_integer() | undefined) ->
    livery_resp:resp().
maybe_reset(Resp, undefined) ->
    Resp;
maybe_reset(Resp, Reset) ->
    livery_resp:with_header(<<"ratelimit-reset">>, integer_to_binary(Reset), Resp).

-spec maybe_retry_after(livery_resp:resp(), non_neg_integer() | undefined) ->
    livery_resp:resp().
maybe_retry_after(Resp, undefined) ->
    Resp;
maybe_retry_after(Resp, Secs) ->
    livery_resp:with_header(<<"retry-after">>, integer_to_binary(Secs), Resp).
