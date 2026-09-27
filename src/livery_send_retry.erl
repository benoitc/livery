-module(livery_send_retry).
-moduledoc """
Internal helper: retry a send the transport refused for backpressure.

quic reports a full connection send queue as `{error, send_queue_full}`:
nothing was written and the same piece should be sent again once the
connection drains. There is no drain notification, so the send is retried
with a short backoff until a deadline. Callers block meanwhile, which is
what gives a streaming producer its backpressure.
""".

-export([run/2]).

-define(FIRST_DELAY, 1).
-define(MAX_DELAY, 50).

-doc """
Call `Send` until it stops returning `{error, send_queue_full}` or the
monotonic `Deadline` (milliseconds) passes, in which case the result is
`{error, send_timeout}`. Any other result is returned as is.
""".
-spec run(fun(() -> R), integer()) -> R | {error, send_timeout} when
    R :: ok | {error, term()}.
run(Send, Deadline) ->
    run(Send, Deadline, ?FIRST_DELAY).

-spec run(fun(() -> R), integer(), pos_integer()) -> R | {error, send_timeout} when
    R :: ok | {error, term()}.
run(Send, Deadline, Delay) ->
    case Send() of
        {error, send_queue_full} ->
            Left = Deadline - erlang:monotonic_time(millisecond),
            case Left > 0 of
                true ->
                    timer:sleep(min(Delay, Left)),
                    run(Send, Deadline, min(Delay * 2, ?MAX_DELAY));
                false ->
                    {error, send_timeout}
            end;
        Other ->
            Other
    end.
