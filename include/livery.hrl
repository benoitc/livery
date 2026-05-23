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
    meta = #{} :: map()
}).

-record(livery_resp, {
    status = 200 :: 100..599,
    headers = [] :: [{binary(), binary()}],
    body = {full, <<>>} ::
        {full, iodata()}
        | {chunked, fun((term()) -> ok | {error, term()})}
        | {sse, fun((term()) -> ok | {error, term()})}
        | {file, file:name_all(), undefined | {non_neg_integer(), non_neg_integer() | eof}}
        | {upgrade, ws | wt, term()}
        | empty
        | taken_over,
    trailers ::
        undefined
        | [{binary(), binary()}]
        | fun(() -> [{binary(), binary()}])
}).

-endif.
