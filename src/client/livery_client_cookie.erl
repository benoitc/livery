-module(livery_client_cookie).
-moduledoc """
Client layer: a cookie jar (RFC 6265, client side).

Before each request it picks the stored cookies that match the target
(host, path, secure) and merges them into one `Cookie` header, keeping any
`Cookie` the caller already set. After the response it parses every
`Set-Cookie` header and updates the jar: a new cookie replaces the one
under the same `(domain, path, name)` key, and an expired one (a past
`Expires`, or `Max-Age` <= 0) deletes it. Add it with
`livery_client:cookie_jar/0,1`.

The jar keeps no cookies of its own; it reads and writes them through a
`livery_client_cookie_store` (default `livery_client_cookie_store_ets`),
an in-memory per-jar store shared across the request processes that run
the client.

This is a subset: no public suffix list, no third-party-cookie policy,
no persistence. `SameSite` is parsed but not enforced.
""".

-export([jar/0, jar/1, call/3]).

-export_type([state/0]).

-define(DEFAULT_MAX_COOKIES, 3000).
%% Seconds between the gregorian epoch (year 0) and the Unix epoch (1970).
-define(UNIX_EPOCH, 62167219200).

-opaque state() :: #{
    module := module(),
    store := livery_client_cookie_store:store(),
    max_cookies := pos_integer()
}.

%% A stored cookie. Opaque to the store; the layer owns this shape.
-type cookie() :: #{
    name := binary(),
    value := binary(),
    domain := binary(),
    path := binary(),
    secure := boolean(),
    http_only := boolean(),
    same_site := binary() | undefined,
    host_only := boolean(),
    expires := non_neg_integer() | session,
    created := integer()
}.

%%====================================================================
%% Constructor
%%====================================================================

-doc "Build a jar with the default ETS store and cookie cap.".
-spec jar() -> state().
jar() -> jar(#{}).

-doc """
Build a jar. `Opts`: `max_cookies` (total cap before the oldest are
evicted, default 3000), `store` (a `livery_client_cookie_store` callback
module, default `livery_client_cookie_store_ets`). Any other keys are
passed through to the store's `init/1`.
""".
-spec jar(map()) -> state().
jar(Opts) ->
    Module = maps:get(store, Opts, livery_client_cookie_store_ets),
    Store = Module:init(Opts),
    #{
        module => Module,
        store => Store,
        max_cookies => maps:get(max_cookies, Opts, ?DEFAULT_MAX_COOKIES)
    }.

%%====================================================================
%% Layer
%%====================================================================

-spec call(livery_client:request(), livery_client:next(), state()) ->
    {ok, livery_client:response()} | {error, term()}.
call(Req, Next, State) ->
    case parse_url(livery_client:url(Req)) of
        {ok, Scheme, Host, Path} ->
            Req1 = attach_cookies(Req, State, Scheme, Host, Path),
            Result = Next(Req1),
            store_response(Result, State, Host, Path),
            Result;
        error ->
            Next(Req)
    end.

%%====================================================================
%% Outbound: select and merge cookies
%%====================================================================

attach_cookies(Req, #{module := Module, store := Store}, Scheme, Host, Path) ->
    Now = erlang:system_time(second),
    Live = drop_expired(Module:get(Store), Now, Module, Store),
    Matching = [C || C <- Live, send_match(C, Scheme, Host, Path)],
    Pairs = [<<N/binary, "=", V/binary>> || #{name := N, value := V} <- sort_cookies(Matching)],
    merge_cookie_header(Req, Pairs).

merge_cookie_header(Req, []) ->
    Req;
merge_cookie_header(Req, Pairs) ->
    Jar = iolist_to_binary(lists:join(<<"; ">>, Pairs)),
    case livery_client:header(<<"cookie">>, Req) of
        undefined ->
            livery_client:set_header(<<"cookie">>, Jar, Req);
        Existing ->
            livery_client:set_header(<<"cookie">>, <<Existing/binary, "; ", Jar/binary>>, Req)
    end.

%% Longest path first; ties broken by earliest creation (RFC 6265 5.4).
sort_cookies(Cookies) ->
    lists:sort(fun(A, B) -> order(A) =< order(B) end, Cookies).

order(#{path := P, created := C}) -> {-byte_size(P), C}.

send_match(#{secure := Secure} = Cookie, Scheme, Host, Path) ->
    secure_ok(Secure, Scheme) andalso
        domain_match(Host, Cookie) andalso
        path_match(Path, maps:get(path, Cookie)).

secure_ok(false, _Scheme) -> true;
secure_ok(true, Scheme) -> Scheme =:= <<"https">>.

domain_match(Host, #{host_only := true, domain := Domain}) ->
    Host =:= Domain;
domain_match(Host, #{host_only := false, domain := Domain}) ->
    Host =:= Domain orelse suffix_match(Host, Domain).

%% Host ends with "." ++ Domain (a proper sub-domain), per RFC 6265 5.1.3.
suffix_match(Host, Domain) ->
    DS = byte_size(Domain),
    HS = byte_size(Host),
    HS > DS andalso
        binary:part(Host, HS - DS, DS) =:= Domain andalso
        binary:at(Host, HS - DS - 1) =:= $..

path_match(Path, Path) ->
    true;
path_match(ReqPath, CookiePath) ->
    PS = byte_size(CookiePath),
    case ReqPath of
        <<CookiePath:PS/binary, $/, _/binary>> -> true;
        <<CookiePath:PS/binary, _/binary>> -> binary:last(CookiePath) =:= $/;
        _ -> false
    end.

%%====================================================================
%% Inbound: parse Set-Cookie and update the jar
%%====================================================================

store_response({ok, Resp}, State, Host, Path) ->
    Values = [V || {N, V} <- livery_client:headers(Resp), string:lowercase(N) =:= <<"set-cookie">>],
    lists:foreach(fun(V) -> ingest(V, State, Host, Path) end, Values),
    enforce_max(State);
store_response(_Other, _State, _Host, _Path) ->
    ok.

ingest(Value, #{module := Module, store := Store}, Host, Path) ->
    case parse_set_cookie(Value, Host, Path) of
        ignore ->
            ok;
        Cookie ->
            Key = key(Cookie),
            case expired(Cookie, erlang:system_time(second)) of
                true -> Module:delete(Store, Key);
                false -> Module:put(Store, Key, Cookie)
            end
    end.

enforce_max(#{module := Module, store := Store, max_cookies := Max}) ->
    All = Module:get(Store),
    case length(All) - Max of
        Excess when Excess =< 0 ->
            ok;
        Excess ->
            Oldest = lists:sublist(lists:sort(fun by_created/2, All), Excess),
            lists:foreach(fun(C) -> Module:delete(Store, key(C)) end, Oldest)
    end.

by_created(#{created := A}, #{created := B}) -> A =< B.

key(#{domain := D, path := P, name := N}) -> {D, P, N}.

expired(#{expires := session}, _Now) -> false;
expired(#{expires := E}, Now) -> E =< Now.

drop_expired(Cookies, Now, Module, Store) ->
    lists:filter(
        fun(C) ->
            case expired(C, Now) of
                true ->
                    Module:delete(Store, key(C)),
                    false;
                false ->
                    true
            end
        end,
        Cookies
    ).

%%====================================================================
%% Set-Cookie parsing (RFC 6265 5.2)
%%====================================================================

-spec parse_set_cookie(binary(), binary(), binary()) -> cookie() | ignore.
parse_set_cookie(Bin, Host, ReqPath) ->
    [NameValue | AttrParts] = binary:split(Bin, <<";">>, [global]),
    case parse_nv(string:trim(NameValue)) of
        ignore -> ignore;
        {Name, Value} -> build_cookie(Name, Value, parse_attrs(AttrParts), Host, ReqPath)
    end.

parse_nv(Seg) ->
    case binary:split(Seg, <<"=">>) of
        [Name0, Value0] ->
            case string:trim(Name0) of
                <<>> -> ignore;
                Name -> {Name, string:trim(Value0)}
            end;
        _ ->
            ignore
    end.

%% Later attributes win: fold prepends, so the head is the last occurrence
%% and keyfind returns it first.
parse_attrs(Parts) ->
    lists:foldl(
        fun(Part, Acc) ->
            case parse_attr(string:trim(Part)) of
                skip -> Acc;
                KV -> [KV | Acc]
            end
        end,
        [],
        Parts
    ).

parse_attr(<<>>) ->
    skip;
parse_attr(Part) ->
    case binary:split(Part, <<"=">>) of
        [K, V] -> {string:lowercase(string:trim(K)), string:trim(V)};
        [K] -> {string:lowercase(string:trim(K)), <<>>}
    end.

build_cookie(Name, Value, Attrs, Host, ReqPath) ->
    Now = erlang:system_time(second),
    {Domain, HostOnly} = domain_attr(attr(<<"domain">>, Attrs), Host),
    #{
        name => Name,
        value => Value,
        domain => Domain,
        path => path_attr(attr(<<"path">>, Attrs), ReqPath),
        secure => has_attr(<<"secure">>, Attrs),
        http_only => has_attr(<<"httponly">>, Attrs),
        same_site => attr(<<"samesite">>, Attrs),
        host_only => HostOnly,
        expires => expiry(Attrs, Now),
        created => Now
    }.

attr(Key, Attrs) ->
    case lists:keyfind(Key, 1, Attrs) of
        {Key, V} -> V;
        false -> undefined
    end.

has_attr(Key, Attrs) -> lists:keymember(Key, 1, Attrs).

%% No Domain => host-only, scoped to the exact request host. With a Domain,
%% strip a leading dot; an IP host ignores any Domain that is not itself.
domain_attr(undefined, Host) ->
    {Host, true};
domain_attr(<<>>, Host) ->
    {Host, true};
domain_attr(Domain0, Host) ->
    Domain = string:lowercase(strip_dot(Domain0)),
    case is_ip(Host) andalso Domain =/= Host of
        true -> {Host, true};
        false -> {Domain, false}
    end.

strip_dot(<<".", Rest/binary>>) -> Rest;
strip_dot(Domain) -> Domain.

is_ip(Host) ->
    case inet:parse_address(binary_to_list(Host)) of
        {ok, _} -> true;
        {error, _} -> false
    end.

path_attr(undefined, ReqPath) -> default_path(ReqPath);
path_attr(<<"/", _/binary>> = Path, _ReqPath) -> Path;
path_attr(_Other, ReqPath) -> default_path(ReqPath).

%% RFC 6265 5.1.4: the request path up to but not including the rightmost
%% slash, or "/" when there is only the leading slash.
default_path(<<"/", _/binary>> = Path) ->
    case binary:matches(Path, <<"/">>) of
        [_] ->
            <<"/">>;
        Matches ->
            case lists:last(Matches) of
                {0, _} -> <<"/">>;
                {Pos, _} -> binary:part(Path, 0, Pos)
            end
    end;
default_path(_Other) ->
    <<"/">>.

%% Max-Age wins over Expires (RFC 6265 5.3). Max-Age <= 0 expires now
%% (sentinel 0, always <= the current time).
expiry(Attrs, Now) ->
    case max_age(attr(<<"max-age">>, Attrs)) of
        {ok, Secs} when Secs =< 0 -> 0;
        {ok, Secs} -> Now + Secs;
        none -> expires(attr(<<"expires">>, Attrs))
    end.

max_age(undefined) ->
    none;
max_age(Bin) ->
    try
        {ok, binary_to_integer(string:trim(Bin))}
    catch
        error:badarg -> none
    end.

expires(undefined) ->
    session;
expires(DateBin) ->
    case parse_http_date(DateBin) of
        {ok, Secs} -> Secs;
        error -> session
    end.

%%====================================================================
%% HTTP-date parsing (RFC 6265 5.1.1: IMF-fixdate, RFC 850, asctime)
%%====================================================================

-spec parse_http_date(binary()) -> {ok, non_neg_integer()} | error.
parse_http_date(Bin) ->
    finalize_date(lists:foldl(fun classify_token/2, #{}, date_tokens(Bin))).

%% Split on the cookie-date delimiter set; ":" is kept so the time stays
%% one token.
date_tokens(Bin) -> date_tokens(Bin, [], []).

date_tokens(<<>>, [], Acc) ->
    lists:reverse(Acc);
date_tokens(<<>>, Cur, Acc) ->
    lists:reverse([lists:reverse(Cur) | Acc]);
date_tokens(<<C, Rest/binary>>, Cur, Acc) ->
    case is_delim(C) of
        true when Cur =:= [] -> date_tokens(Rest, [], Acc);
        true -> date_tokens(Rest, [], [lists:reverse(Cur) | Acc]);
        false -> date_tokens(Rest, [C | Cur], Acc)
    end.

is_delim(C) ->
    C =:= 16#09 orelse
        (C >= 16#20 andalso C =< 16#2F) orelse
        (C >= 16#3B andalso C =< 16#40) orelse
        (C >= 16#5B andalso C =< 16#60) orelse
        (C >= 16#7B andalso C =< 16#7E).

classify_token(Tok, Fields) ->
    case parse_time(Tok) of
        {ok, H, Mi, S} when not is_map_key(time, Fields) ->
            Fields#{time => true, h => H, mi => Mi, s => S};
        _ ->
            classify_dmy(Tok, Fields)
    end.

classify_dmy(Tok, Fields) ->
    case day(Tok) of
        {ok, D} when not is_map_key(day, Fields) -> Fields#{day => D};
        _ -> classify_my(Tok, Fields)
    end.

classify_my(Tok, Fields) ->
    case month(Tok) of
        {ok, M} when not is_map_key(month, Fields) -> Fields#{month => M};
        _ -> classify_year(Tok, Fields)
    end.

classify_year(Tok, Fields) ->
    case year(Tok) of
        {ok, Y} when not is_map_key(year, Fields) -> Fields#{year => Y};
        _ -> Fields
    end.

parse_time(Tok) ->
    case string:lexemes(Tok, ":") of
        [H, Mi, S] ->
            case {num(H), num(Mi), num(S)} of
                {{ok, Hn}, {ok, Min}, {ok, Sn}} when Hn =< 23, Min =< 59, Sn =< 60 ->
                    {ok, Hn, Min, Sn};
                _ ->
                    error
            end;
        _ ->
            error
    end.

day(Tok) when length(Tok) =< 2 ->
    case num(Tok) of
        {ok, D} when D >= 1, D =< 31 -> {ok, D};
        _ -> error
    end;
day(_Tok) ->
    error.

year(Tok) when length(Tok) =< 4 ->
    case num(Tok) of
        {ok, Y} -> {ok, fix_year(Y)};
        error -> error
    end;
year(_Tok) ->
    error.

fix_year(Y) when Y >= 70, Y =< 99 -> Y + 1900;
fix_year(Y) when Y >= 0, Y =< 69 -> Y + 2000;
fix_year(Y) -> Y.

month(Tok) when length(Tok) >= 3 ->
    month_num(string:lowercase(string:slice(Tok, 0, 3)));
month(_Tok) ->
    error.

month_num("jan") -> {ok, 1};
month_num("feb") -> {ok, 2};
month_num("mar") -> {ok, 3};
month_num("apr") -> {ok, 4};
month_num("may") -> {ok, 5};
month_num("jun") -> {ok, 6};
month_num("jul") -> {ok, 7};
month_num("aug") -> {ok, 8};
month_num("sep") -> {ok, 9};
month_num("oct") -> {ok, 10};
month_num("nov") -> {ok, 11};
month_num("dec") -> {ok, 12};
month_num(_Other) -> error.

num([]) ->
    error;
num(Str) ->
    case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Str) of
        true -> {ok, list_to_integer(Str)};
        false -> error
    end.

finalize_date(#{day := D, month := Mo, year := Y, h := H, mi := Mi, s := S}) ->
    case calendar:valid_date(Y, Mo, D) of
        true ->
            Greg = calendar:datetime_to_gregorian_seconds({{Y, Mo, D}, {H, Mi, S}}),
            {ok, Greg - ?UNIX_EPOCH};
        false ->
            error
    end;
finalize_date(_Incomplete) ->
    error.

%%====================================================================
%% URL parsing
%%====================================================================

parse_url(Url) ->
    case uri_string:parse(Url) of
        #{host := Host} = Map ->
            {ok, scheme(Map), string:lowercase(Host), path(Map)};
        _ ->
            error
    end.

scheme(#{scheme := S}) -> string:lowercase(S);
scheme(_Map) -> <<>>.

path(#{path := <<>>}) -> <<"/">>;
path(#{path := P}) -> P;
path(_Map) -> <<"/">>.
