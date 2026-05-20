-module(livery_ext).
-moduledoc """
Request extractors.

Axum-style helpers that pull typed values out of a request. Each
extractor either returns the value directly or a
`{ok, _} | {error, _}` result. Extractors are pure functions over
`#livery_req{}`; they never block on the wire. Body-shaped
extractors require the body to have been read into a buffer first
(the per-request process does that before invoking the handler
when the route is configured for buffered intake).
""".

-include("livery.hrl").

-export([
    json/1,
    form/1,
    path_param/2,
    query/2,
    header/2,
    bearer_token/1,
    cookie/2,
    user/1,
    user/2,
    session/1,
    session/2
]).

-export_type([json_error/0, form_error/0]).

-type json_error() :: no_body | invalid_json | not_buffered.
-type form_error() :: no_body | not_buffered.

%%====================================================================
%% Body extractors
%%====================================================================

-doc """
Decode the request body as JSON using the OTP `json` module.

The body must have been buffered. Streaming bodies must be drained
via `livery_body:read_all/1` before calling this.
""".
-spec json(livery_req:req()) -> {ok, term()} | {error, json_error()}.
json(#livery_req{body = empty}) ->
    {error, no_body};
json(#livery_req{body = {buffered, IoData}}) ->
    Bin = iolist_to_binary(IoData),
    try
        {ok, json:decode(Bin)}
    catch
        _:_ -> {error, invalid_json}
    end;
json(#livery_req{body = {stream, _}}) ->
    {error, not_buffered}.

-doc """
Decode an `application/x-www-form-urlencoded` body into a list of
key/value pairs.
""".
-spec form(livery_req:req()) ->
    {ok, [{binary(), binary()}]} | {error, form_error()}.
form(#livery_req{body = empty}) ->
    {error, no_body};
form(#livery_req{body = {buffered, IoData}}) ->
    {ok, decode_form(iolist_to_binary(IoData))};
form(#livery_req{body = {stream, _}}) ->
    {error, not_buffered}.

%%====================================================================
%% Path, query, header, auth
%%====================================================================

-doc "Look up a path parameter (e.g. `:name` in `/users/:name`).".
-spec path_param(binary(), livery_req:req()) -> binary() | undefined.
path_param(Name, Req) ->
    livery_req:binding(Name, Req).

-doc """
Look up a single query string parameter.

Returns the first value if the key appears more than once.
""".
-spec query(binary(), livery_req:req()) -> binary() | undefined.
query(Name, Req) ->
    Raw = livery_req:query(Req),
    case lists:keyfind(Name, 1, decode_form(Raw)) of
        {_, V} -> V;
        false  -> undefined
    end.

-doc "Look up a header by name. Names are matched case-insensitively.".
-spec header(binary(), livery_req:req()) -> binary() | undefined.
header(Name, Req) ->
    livery_req:header(Name, Req).

-doc """
Extract a bearer token from the `Authorization` header.

Accepts `Bearer `, `bearer `, and `BEARER ` prefixes (RFC 6750
§2.1 makes the scheme case-insensitive).
""".
-spec bearer_token(livery_req:req()) -> binary() | undefined.
bearer_token(Req) ->
    case livery_req:header(<<"authorization">>, Req) of
        undefined -> undefined;
        Value ->
            case parse_bearer(Value) of
                {ok, Token} -> Token;
                error       -> undefined
            end
    end.

-spec parse_bearer(binary()) -> {ok, binary()} | error.
parse_bearer(<<"Bearer ", T/binary>>) -> {ok, T};
parse_bearer(<<"bearer ", T/binary>>) -> {ok, T};
parse_bearer(<<"BEARER ", T/binary>>) -> {ok, T};
parse_bearer(_) -> error.

-doc """
Return the value of a request cookie by name.

Parses the `Cookie` header (RFC 6265 `name=value` pairs separated
by `; `). Returns `undefined` when the header or the named cookie
is absent.
""".
-spec cookie(binary(), livery_req:req()) -> binary() | undefined.
cookie(Name, Req) ->
    case livery_req:header(<<"cookie">>, Req) of
        undefined -> undefined;
        Value     -> find_cookie(Name, Value)
    end.

-spec find_cookie(binary(), binary()) -> binary() | undefined.
find_cookie(Name, Header) ->
    Pairs = binary:split(Header, <<";">>, [global]),
    lists:foldl(fun
        (_Pair, Found) when Found =/= undefined -> Found;
        (Pair, undefined) ->
            case binary:split(string:trim(Pair), <<"=">>) of
                [Name, Value] -> Value;
                _             -> undefined
            end
    end, undefined, Pairs).

-doc """
Return the authenticated principal stored on the request.

`livery_auth_bearer` (and other auth middlewares) place the
verified claims under `meta(user, _)`. Returns `undefined` when no
auth middleware ran or authentication was optional and absent.
""".
-spec user(livery_req:req()) -> term() | undefined.
user(Req) ->
    livery_req:meta(user, Req).

-doc "`user/1` with a fallback default.".
-spec user(livery_req:req(), Default) -> term() | Default.
user(Req, Default) ->
    livery_req:meta(user, Req, Default).

-doc """
Return the session map stored on the request.

`livery_auth_session` places the verified session payload under
`meta(session, _)`. Returns `undefined` when no session middleware
ran or no valid session cookie was present.
""".
-spec session(livery_req:req()) -> term() | undefined.
session(Req) ->
    livery_req:meta(session, Req).

-doc "`session/1` with a fallback default.".
-spec session(livery_req:req(), Default) -> term() | Default.
session(Req, Default) ->
    livery_req:meta(session, Req, Default).

%%====================================================================
%% URL-encoded form decoding
%%====================================================================

-spec decode_form(binary()) -> [{binary(), binary()}].
decode_form(<<>>) -> [];
decode_form(Bin) ->
    [decode_pair(P) || P <- binary:split(Bin, <<"&">>, [global]), P =/= <<>>].

-spec decode_pair(binary()) -> {binary(), binary()}.
decode_pair(P) ->
    case binary:split(P, <<"=">>) of
        [K, V] -> {url_decode(K), url_decode(V)};
        [K]    -> {url_decode(K), <<>>}
    end.

-spec url_decode(binary()) -> binary().
url_decode(B) -> url_decode(B, <<>>).

-spec url_decode(binary(), binary()) -> binary().
url_decode(<<>>, Acc) ->
    Acc;
url_decode(<<$+, R/binary>>, Acc) ->
    url_decode(R, <<Acc/binary, $\s>>);
url_decode(<<$%, H1, H2, R/binary>>, Acc) ->
    case unhex(H1, H2) of
        {ok, C} -> url_decode(R, <<Acc/binary, C>>);
        error   -> url_decode(R, <<Acc/binary, $%, H1, H2>>)
    end;
url_decode(<<C, R/binary>>, Acc) ->
    url_decode(R, <<Acc/binary, C>>).

-spec unhex(byte(), byte()) -> {ok, byte()} | error.
unhex(H1, H2) ->
    case {hex(H1), hex(H2)} of
        {{ok, X}, {ok, Y}} -> {ok, X * 16 + Y};
        _ -> error
    end.

-spec hex(byte()) -> {ok, 0..15} | error.
hex(C) when C >= $0, C =< $9 -> {ok, C - $0};
hex(C) when C >= $a, C =< $f -> {ok, C - $a + 10};
hex(C) when C >= $A, C =< $F -> {ok, C - $A + 10};
hex(_) -> error.
