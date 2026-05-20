-module(livery_timeout).
-moduledoc """
Per-request deadline middleware.

State: `#{after_ms => Ms}`. If the rest of the pipeline does not
return within the deadline, the worker is killed and a 504 is
emitted instead. A handler crash maps to 500.

The deadline is enforced by running the downstream call in a
spawned, monitored process. Handlers that receive body chunks via
`livery_body:read/2` will not see those chunks under this
middleware in Phase 1, because body messages target the parent
request process. Pair `livery_timeout` with a body-buffering
middleware in front of it, or apply it to routes whose handlers
do not stream input. Adapter-level cancellation lands in Phase 2
and removes this limitation.
""".
-behaviour(livery_middleware).

-export([call/3]).

-doc "Enforce the deadline. Crashes map to 500, timeouts to 504.".
-spec call(livery_req:req(), livery_middleware:next(),
           #{after_ms := pos_integer()}) -> livery_resp:resp().
call(Req, Next, #{after_ms := Ms}) when is_integer(Ms), Ms > 0 ->
    Self = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() ->
        try
            Self ! {Ref, {ok, Next(Req)}}
        catch
            Class:Reason:Stack ->
                Self ! {Ref, {crash, Class, Reason, Stack}}
        end
    end),
    receive
        {Ref, {ok, Resp}} ->
            erlang:demonitor(MRef, [flush]),
            Resp;
        {Ref, {crash, _Class, _Reason, _Stack}} ->
            erlang:demonitor(MRef, [flush]),
            livery_resp:text(500, <<"internal server error">>);
        {'DOWN', MRef, process, Pid, _Reason} ->
            livery_resp:text(500, <<"internal server error">>)
    after Ms ->
        exit(Pid, kill),
        erlang:demonitor(MRef, [flush]),
        livery_resp:text(504, <<"request timeout">>)
    end.
