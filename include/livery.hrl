%% livery.hrl - Common record definitions and macros

-ifndef(LIVERY_HRL).
-define(LIVERY_HRL, 1).

%% Request record
-record(livery_req, {
    method      :: binary(),
    path        :: binary(),
    qs          :: binary(),
    version     :: {1, 0} | {1, 1} | {2, 0} | {3, 0},
    headers     :: [{binary(), binary()}],
    body        :: binary() | undefined,
    peer        :: {inet:ip_address(), inet:port_number()} | undefined,
    sock        :: gen_tcp:socket() | ssl:sslsocket() | undefined,
    handler     :: module(),
    handler_opts :: term(),
    %% Internal state
    has_body    :: boolean(),
    body_length :: non_neg_integer() | chunked | undefined
}).

%% Default limits
-define(MAX_METHOD_SIZE, 16).
-define(MAX_URI_SIZE, 8192).
-define(MAX_HEADER_NAME_SIZE, 256).
-define(MAX_HEADER_VALUE_SIZE, 8192).
-define(MAX_HEADERS, 100).

%% HTTP versions
-define(HTTP_1_0, {1, 0}).
-define(HTTP_1_1, {1, 1}).

%% Common status codes
-define(HTTP_200, 200).
-define(HTTP_201, 201).
-define(HTTP_204, 204).
-define(HTTP_301, 301).
-define(HTTP_302, 302).
-define(HTTP_304, 304).
-define(HTTP_400, 400).
-define(HTTP_401, 401).
-define(HTTP_403, 403).
-define(HTTP_404, 404).
-define(HTTP_405, 405).
-define(HTTP_500, 500).
-define(HTTP_501, 501).
-define(HTTP_503, 503).

-endif.
