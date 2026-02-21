%% @doc Request API for accessing request data.
-module(livery_req).

-include("livery.hrl").

-export([
    method/1,
    path/1,
    qs/1,
    version/1,
    headers/1,
    header/2,
    header/3,
    body/1,
    has_body/1,
    body_length/1,
    peer/1,
    %% Convenience accessors
    scheme/1,
    host/1,
    port/1,
    content_type/1,
    content_length/1,
    accept/1,
    user_agent/1,
    is_websocket_upgrade/1,
    is_ssl/1
]).

-export([
    new/0,
    set_method/2,
    set_path/2,
    set_qs/2,
    set_version/2,
    set_headers/2,
    set_body/2,
    set_peer/2,
    set_sock/2,
    set_handler/3,
    set_body_info/3
]).

-export_type([req/0]).

-type req() :: #livery_req{}.

%% Accessors

-spec method(req()) -> binary().
method(#livery_req{method = Method}) ->
    Method.

-spec path(req()) -> binary().
path(#livery_req{path = Path}) ->
    Path.

-spec qs(req()) -> binary().
qs(#livery_req{qs = Qs}) ->
    Qs.

-spec version(req()) -> {non_neg_integer(), non_neg_integer()}.
version(#livery_req{version = Version}) ->
    Version.

-spec headers(req()) -> [{binary(), binary()}].
headers(#livery_req{headers = Headers}) ->
    Headers.

-spec header(binary(), req()) -> binary() | undefined.
header(Name, Req) ->
    header(Name, Req, undefined).

-spec header(binary(), req(), Default) -> binary() | Default when Default :: term().
header(Name, #livery_req{headers = Headers}, Default) ->
    LowerName = string:lowercase(Name),
    case lists:keyfind(LowerName, 1, Headers) of
        {_, Value} -> Value;
        false -> Default
    end.

-spec body(req()) -> binary() | undefined.
body(#livery_req{body = Body}) ->
    Body.

-spec has_body(req()) -> boolean().
has_body(#livery_req{has_body = HasBody}) ->
    HasBody.

-spec body_length(req()) -> non_neg_integer() | chunked | undefined.
body_length(#livery_req{body_length = Length}) ->
    Length.

-spec peer(req()) -> {inet:ip_address(), inet:port_number()} | undefined.
peer(#livery_req{peer = Peer}) ->
    Peer.

%% Setters (for internal use)

-spec new() -> req().
new() ->
    #livery_req{
        method = <<>>,
        path = <<>>,
        qs = <<>>,
        version = {1, 1},
        headers = [],
        body = undefined,
        peer = undefined,
        sock = undefined,
        handler = undefined,
        handler_opts = [],
        has_body = false,
        body_length = undefined
    }.

-spec set_method(binary(), req()) -> req().
set_method(Method, Req) ->
    Req#livery_req{method = Method}.

-spec set_path(binary(), req()) -> req().
set_path(Path, Req) ->
    Req#livery_req{path = Path}.

-spec set_qs(binary(), req()) -> req().
set_qs(Qs, Req) ->
    Req#livery_req{qs = Qs}.

-spec set_version({non_neg_integer(), non_neg_integer()}, req()) -> req().
set_version(Version, Req) ->
    Req#livery_req{version = Version}.

-spec set_headers([{binary(), binary()}], req()) -> req().
set_headers(Headers, Req) ->
    Req#livery_req{headers = Headers}.

-spec set_body(binary(), req()) -> req().
set_body(Body, Req) ->
    Req#livery_req{body = Body}.

-spec set_peer({inet:ip_address(), inet:port_number()}, req()) -> req().
set_peer(Peer, Req) ->
    Req#livery_req{peer = Peer}.

-spec set_sock(gen_tcp:socket() | ssl:sslsocket(), req()) -> req().
set_sock(Sock, Req) ->
    Req#livery_req{sock = Sock}.

-spec set_handler(module(), term(), req()) -> req().
set_handler(Handler, Opts, Req) ->
    Req#livery_req{handler = Handler, handler_opts = Opts}.

-spec set_body_info(boolean(), non_neg_integer() | chunked | undefined, req()) -> req().
set_body_info(HasBody, Length, Req) ->
    Req#livery_req{has_body = HasBody, body_length = Length}.

%% Convenience accessors

-spec scheme(req()) -> http | https.
scheme(#livery_req{sock = Sock}) ->
    case Sock of
        {sslsocket, _, _} -> https;
        _ -> http
    end.

-spec host(req()) -> binary() | undefined.
host(Req) ->
    header(<<"host">>, Req).

-spec port(req()) -> inet:port_number() | undefined.
port(#livery_req{sock = Sock}) ->
    case Sock of
        undefined -> undefined;
        {sslsocket, _, _} ->
            case ssl:sockname(Sock) of
                {ok, {_, Port}} -> Port;
                _ -> undefined
            end;
        _ ->
            case inet:sockname(Sock) of
                {ok, {_, Port}} -> Port;
                _ -> undefined
            end
    end.

-spec content_type(req()) -> binary() | undefined.
content_type(Req) ->
    case header(<<"content-type">>, Req) of
        undefined -> undefined;
        CT -> hd(binary:split(CT, <<";">>))  % Strip charset, boundary, etc.
    end.

-spec content_length(req()) -> non_neg_integer() | undefined.
content_length(Req) ->
    case header(<<"content-length">>, Req) of
        undefined -> undefined;
        Value ->
            try binary_to_integer(Value)
            catch _:_ -> undefined
            end
    end.

-spec accept(req()) -> binary() | undefined.
accept(Req) ->
    header(<<"accept">>, Req).

-spec user_agent(req()) -> binary() | undefined.
user_agent(Req) ->
    header(<<"user-agent">>, Req).

-spec is_websocket_upgrade(req()) -> boolean().
is_websocket_upgrade(Req) ->
    case header(<<"upgrade">>, Req) of
        undefined -> false;
        Upgrade ->
            LowerUpgrade = string:lowercase(Upgrade),
            LowerUpgrade =:= <<"websocket">>
    end.

-spec is_ssl(req()) -> boolean().
is_ssl(#livery_req{sock = Sock}) ->
    case Sock of
        {sslsocket, _, _} -> true;
        _ -> false
    end.
