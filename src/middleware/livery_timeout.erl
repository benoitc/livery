-module(livery_timeout).
-moduledoc """
Per-request deadline middleware.

State: `#{after_ms => Ms}`. If the rest of the pipeline does not
return within the deadline, it is stopped and a 504 is emitted
instead. A handler crash maps to 500.

The deadline is enforced by running the rest of the pipeline in a
monitored process, which the middleware kills when the time is up.
That process carries the request worker's context, so the rest of the
pipeline behaves as if it ran in the worker:

- it starts with a copy of the worker's process dictionary (logger
  metadata, the trace context, anything an outer middleware put
  there);
- hooks registered with `livery_middleware:after_emit/1` run in the
  worker after the response is sent, also when the deadline kills the
  request, so a `livery_concurrency` slot taken behind the timeout is
  always given back;
- the request body and the disconnect notice, which the adapter sends
  to the worker, are passed on as they arrive, so the handler can read
  a streamed body and see `{livery_disconnect, _, _}`.

What the process changes in its own dictionary is not copied back.
""".
-behaviour(livery_middleware).

-export([call/3]).

-doc "Enforce the deadline. Crashes map to 500, timeouts to 504.".
-spec call(
    livery_req:req(),
    livery_middleware:next(),
    #{after_ms := pos_integer()}
) -> livery_resp:resp().
call(Req, Next, #{after_ms := Ms}) when is_integer(Ms), Ms > 0 ->
    Self = self(),
    Tag = make_ref(),
    Context = livery_middleware:capture_context(Tag),
    {Pid, MRef} = spawn_monitor(fun() ->
        ok = livery_middleware:adopt_context(Context),
        try
            Self ! {Tag, {ok, Next(Req)}}
        catch
            Class:Reason:Stack ->
                Self ! {Tag, {crash, Class, Reason, Stack}}
        end
    end),
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    wait(#{pid => Pid, mref => MRef, tag => Tag, body => body_ref(Req)}, Deadline).

%% Body chunks for this request carry the reader's reference.
-spec body_ref(livery_req:req()) -> reference() | undefined.
body_ref(Req) ->
    case livery_req:body(Req) of
        {stream, Reader} -> livery_body:ref(Reader);
        _ -> undefined
    end.

-spec wait(map(), integer()) -> livery_resp:resp().
wait(#{pid := Pid, mref := MRef, tag := Tag, body := BodyRef} = Run, Deadline) ->
    Disconnect = livery_req:disconnect_tag(),
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Tag, {after_emit, Fun}} ->
            _ = livery_middleware:after_emit(Fun),
            wait(Run, Deadline);
        {Tag, {ok, Resp}} ->
            erlang:demonitor(MRef, [flush]),
            Resp;
        {Tag, {crash, _Class, _Reason, _Stack}} ->
            erlang:demonitor(MRef, [flush]),
            livery_resp:text(500, <<"internal server error">>);
        {livery_body, BodyRef, _} = Chunk when BodyRef =/= undefined ->
            Pid ! Chunk,
            wait(Run, Deadline);
        {Disconnect, _, _} = Notice ->
            Pid ! Notice,
            wait(Run, Deadline);
        {'DOWN', MRef, process, Pid, _Reason} ->
            adopt_hooks(Tag),
            livery_resp:text(500, <<"internal server error">>)
    after Left ->
        exit(Pid, kill),
        %% Everything the process sent arrives before its DOWN, so the
        %% hooks it registered are all in the mailbox once DOWN is.
        receive
            {'DOWN', MRef, process, Pid, _} -> ok
        end,
        adopt_hooks(Tag),
        livery_resp:text(504, <<"request timeout">>)
    end.

-spec adopt_hooks(reference()) -> ok.
adopt_hooks(Tag) ->
    receive
        {Tag, {after_emit, Fun}} ->
            _ = livery_middleware:after_emit(Fun),
            adopt_hooks(Tag)
    after 0 ->
        ok
    end.
