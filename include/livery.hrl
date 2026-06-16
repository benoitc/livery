-ifndef(LIVERY_HRL).
-define(LIVERY_HRL, true).

-record(livery_req, {
    protocol = h1 :: h1 | h2 | h3,
    method = <<"GET">> :: binary(),
    scheme = <<"http">> :: binary(),
    authority = <<>> :: binary(),
    path = <<"/">> :: binary(),
    raw_query = <<>> :: binary(),
    bindings = #{} :: #{binary() => binary()},
    headers = [] :: [{binary(), binary()}],
    peer = undefined :: {inet:ip_address(), inet:port_number()} | undefined,
    tls = undefined :: undefined | map(),
    body = empty ::
        empty
        | {buffered, iodata()}
        | {stream, term()},
    adapter = undefined :: module() | undefined,
    stream = undefined :: term(),
    engine_pid = undefined :: pid() | undefined,
    notifier_pid = undefined :: pid() | undefined,
    disc_ref = undefined :: reference() | undefined,
    req_id = <<>> :: binary(),
    started_at = undefined :: integer() | undefined,
    meta = #{} :: map(),
    config = undefined :: term()
}).

-record(livery_resp, {
    status = 200 :: 100..599,
    headers = [] :: [{binary(), binary()}],
    body = {full, <<>>} ::
        {full, iodata()}
        | {chunked, fun((term()) -> ok | {error, term()})}
        | {sse, fun((term()) -> ok | {error, term()})}
        | {deferred, fun(() -> term())}
        | {file, file:name_all(), undefined | {non_neg_integer(), non_neg_integer() | eof}}
        | {upgrade, ws | wt, term()}
        | empty
        | taken_over,
    trailers ::
        undefined
        | [{binary(), binary()}]
        | fun(() -> [{binary(), binary()}]),
    %% Early-response inbound-drain budget for HTTP/1.1. When a handler
    %% commits this response before the request body is fully read, h1
    %% drains the leftover inbound body before closing so the client
    %% reads the response. `default' uses the listener budget; `none'
    %% disables the drain (close immediately); `{MaxBytes, MaxMs}' (either
    %% component `infinity') bounds it for this response only. Honored on
    %% full responses; streaming responses use the listener budget.
    early_response_drain = default ::
        default
        | none
        | {non_neg_integer() | infinity, non_neg_integer() | infinity}
}).

-endif.
