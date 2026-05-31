-module(livery_access_log).
-moduledoc """
Access-log middleware.

Emits one structured log entry per completed request via the OTP
`logger` module. Pairs cleanly with `livery_request_id`: the id
is included in the entry so log aggregators can join request lines
with the response sent to the client.

The log level defaults to `info` and can be overridden in state:
`#{level => debug | info | notice | ...}`.
""".
-behaviour(livery_middleware).

-export([call/3]).

-doc "Run the handler and log one entry on the way out.".
-spec call(livery_req:req(), livery_middleware:next(), map()) ->
    livery_resp:resp().
call(Req, Next, State) ->
    Start = erlang:monotonic_time(microsecond),
    Resp = Next(Req),
    Elapsed = erlang:monotonic_time(microsecond) - Start,
    Level = maps:get(level, State, info),
    logger:log(Level, #{
        msg => "livery_access",
        protocol => livery_req:protocol(Req),
        method => sanitize(livery_req:method(Req)),
        path => sanitize(livery_req:path(Req)),
        status => livery_resp:status(Resp),
        duration_us => Elapsed,
        request_id => livery_req:req_id(Req)
    }),
    Resp.

%% Replace control bytes (including CR/LF) in attacker-controlled fields
%% so a crafted path/method cannot forge extra log lines.
-spec sanitize(binary()) -> binary().
sanitize(Bin) when is_binary(Bin) ->
    <<
        <<(control_to_space(B))>>
     || <<B>> <= Bin
    >>.

-spec control_to_space(byte()) -> byte().
control_to_space(B) when B < 32; B =:= 127 -> $\s;
control_to_space(B) -> B.
