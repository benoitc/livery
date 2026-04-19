-ifndef(LIVERY_HRL).
-define(LIVERY_HRL, true).

-record(livery_req, {
    protocol :: h1 | h2 | h3,
    method :: binary(),
    scheme = <<"http">> :: binary(),
    authority = <<>> :: binary(),
    path = <<"/">> :: binary(),
    raw_query = <<>> :: binary(),
    bindings = #{} :: #{binary() => binary()},
    headers = [] :: [{binary(), binary()}],
    peer :: {inet:ip_address(), inet:port_number()} | undefined,
    tls :: undefined | map(),
    body = empty :: empty
                  | {buffered, iodata()}
                  | {stream, term()},
    adapter :: module() | undefined,
    stream :: term(),
    engine_pid :: pid() | undefined,
    req_id = <<>> :: binary(),
    started_at :: integer() | undefined,
    meta = #{} :: map()
}).

-record(livery_resp, {
    status = 200 :: 100..599,
    headers = [] :: [{binary(), binary()}],
    body = {full, <<>>} :: {full, iodata()}
                         | {chunked, fun((term()) -> ok)}
                         | {sse, fun((term()) -> ok)}
                         | {file, file:name_all(), undefined | {non_neg_integer(), non_neg_integer() | eof}}
                         | {upgrade, ws | wt, term()}
                         | empty,
    trailers :: undefined
              | [{binary(), binary()}]
              | fun(() -> [{binary(), binary()}])
}).

-endif.
