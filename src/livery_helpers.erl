%% @doc Convenience helpers for Livery HTTP handlers.
%%
%% This module provides common operations for building HTTP handlers:
%% - Query string parsing
%% - Form body parsing
%% - JSON helpers (using OTP 27+ json module)
%% - Common response patterns
%% - Cookie handling
%% - Path bindings access
%% - Content negotiation
-module(livery_helpers).

-include("livery.hrl").

%% Query String Parsing
-export([
    parse_qs/1,
    get_qs_value/2,
    get_qs_value/3
]).

%% Form Body Parsing
-export([
    parse_form/1,
    parse_multipart/1,
    get_multipart_boundary/1
]).

%% JSON Helpers
-export([
    json_body/1,
    reply_json/3,
    reply_json/4
]).

%% Common Response Helpers
-export([
    reply_text/3,
    reply_html/3,
    reply_file/3,
    reply_redirect/2,
    reply_redirect/3,
    reply_not_found/1,
    reply_bad_request/2,
    reply_internal_error/2
]).

%% Cookie Helpers
-export([
    get_cookie/2,
    get_cookie/3,
    set_cookie/3,
    delete_cookie/1
]).

%% Path Bindings
-export([
    binding/2,
    binding/3,
    bindings/1
]).

%% Content Negotiation
-export([
    accepts/2,
    accepts_json/1,
    accepts_html/1,
    preferred_type/2
]).

-type part() :: #{
    name := binary(),
    filename => binary(),
    content_type => binary(),
    data := binary()
}.

-type cookie_opts() :: #{
    path => binary(),
    domain => binary(),
    max_age => non_neg_integer(),
    secure => boolean(),
    http_only => boolean(),
    same_site => strict | lax | none
}.

-export_type([part/0, cookie_opts/0]).

%%====================================================================
%% Query String Parsing
%%====================================================================

%% @doc Parse query string to map.
-spec parse_qs(#livery_req{}) -> #{binary() => binary()}.
parse_qs(Req) ->
    QS = livery_req:qs(Req),
    case QS of
        <<>> -> #{};
        _ ->
            Parts = uri_string:dissect_query(QS),
            maps:from_list([{unicode:characters_to_binary(K),
                             unicode:characters_to_binary(V)}
                            || {K, V} <- Parts])
    end.

%% @doc Get single query string parameter.
-spec get_qs_value(binary(), #livery_req{}) -> binary() | undefined.
get_qs_value(Name, Req) ->
    get_qs_value(Name, Req, undefined).

%% @doc Get query string parameter with default.
-spec get_qs_value(binary(), #livery_req{}, Default) -> binary() | Default
    when Default :: term().
get_qs_value(Name, Req, Default) ->
    QS = parse_qs(Req),
    maps:get(Name, QS, Default).

%%====================================================================
%% Form Body Parsing
%%====================================================================

%% @doc Parse application/x-www-form-urlencoded body.
-spec parse_form(#livery_req{}) -> #{binary() => binary()}.
parse_form(Req) ->
    Body = livery_req:body(Req),
    case Body of
        undefined -> #{};
        <<>> -> #{};
        _ ->
            Parts = uri_string:dissect_query(Body),
            maps:from_list([{unicode:characters_to_binary(K),
                             unicode:characters_to_binary(V)}
                            || {K, V} <- Parts])
    end.

%% @doc Extract boundary from Content-Type header for multipart parsing.
-spec get_multipart_boundary(#livery_req{}) -> {ok, binary()} | {error, no_boundary}.
get_multipart_boundary(Req) ->
    case livery_req:header(<<"content-type">>, Req) of
        undefined -> {error, no_boundary};
        CT ->
            case binary:match(CT, <<"boundary=">>) of
                nomatch -> {error, no_boundary};
                {Pos, Len} ->
                    BoundaryStart = Pos + Len,
                    Rest = binary:part(CT, BoundaryStart, byte_size(CT) - BoundaryStart),
                    %% Remove quotes if present
                    Boundary = case Rest of
                        <<$", Quoted/binary>> ->
                            case binary:match(Quoted, <<$">>) of
                                {EndPos, _} -> binary:part(Quoted, 0, EndPos);
                                nomatch -> Quoted
                            end;
                        _ ->
                            %% Take until ; or end
                            case binary:match(Rest, <<";">>) of
                                {EndPos, _} -> binary:part(Rest, 0, EndPos);
                                nomatch -> Rest
                            end
                    end,
                    {ok, string:trim(Boundary)}
            end
    end.

%% @doc Parse multipart/form-data body.
-spec parse_multipart(#livery_req{}) -> {ok, [part()]} | {error, term()}.
parse_multipart(Req) ->
    case get_multipart_boundary(Req) of
        {error, _} = Error -> Error;
        {ok, Boundary} ->
            Body = livery_req:body(Req),
            case Body of
                undefined -> {ok, []};
                <<>> -> {ok, []};
                _ -> parse_multipart_body(Body, Boundary)
            end
    end.

parse_multipart_body(Body, Boundary) ->
    Delimiter = <<"--", Boundary/binary>>,
    EndDelimiter = <<"--", Boundary/binary, "--">>,
    %% Split by delimiter
    Parts = binary:split(Body, Delimiter, [global]),
    %% Filter and parse parts
    ParsedParts = lists:filtermap(
        fun(Part) ->
            case parse_multipart_part(Part, EndDelimiter) of
                skip -> false;
                {ok, Parsed} -> {true, Parsed}
            end
        end,
        Parts
    ),
    {ok, ParsedParts}.

parse_multipart_part(<<>>, _EndDelimiter) ->
    skip;
parse_multipart_part(<<"--", _/binary>>, _EndDelimiter) ->
    skip;
parse_multipart_part(<<"\r\n">>, _EndDelimiter) ->
    skip;
parse_multipart_part(Part, EndDelimiter) ->
    %% Check for end delimiter
    case binary:match(Part, EndDelimiter) of
        {0, _} -> skip;
        _ ->
            %% Split headers from body
            case binary:match(Part, <<"\r\n\r\n">>) of
                nomatch -> skip;
                {HeaderEnd, _} ->
                    %% Skip leading CRLF if present
                    HeaderStart = case Part of
                        <<"\r\n", _/binary>> -> 2;
                        _ -> 0
                    end,
                    HeadersBin = binary:part(Part, HeaderStart, HeaderEnd - HeaderStart),
                    BodyStart = HeaderEnd + 4,
                    BodyBin = binary:part(Part, BodyStart, byte_size(Part) - BodyStart),
                    %% Remove trailing CRLF
                    CleanBody = case binary:match(BodyBin, <<"\r\n">>, [{scope, {byte_size(BodyBin) - 2, 2}}]) of
                        {Pos, _} -> binary:part(BodyBin, 0, Pos);
                        nomatch -> BodyBin
                    end,
                    parse_part_headers(HeadersBin, CleanBody)
            end
    end.

parse_part_headers(HeadersBin, Body) ->
    Headers = parse_headers(HeadersBin),
    case proplists:get_value(<<"content-disposition">>, Headers) of
        undefined -> skip;
        Disposition ->
            PartMap = parse_disposition(Disposition),
            case maps:get(name, PartMap, undefined) of
                undefined -> skip;
                Name ->
                    ContentType = proplists:get_value(<<"content-type">>, Headers),
                    Result = #{name => Name, data => Body},
                    Result1 = case maps:get(filename, PartMap, undefined) of
                        undefined -> Result;
                        Filename -> Result#{filename => Filename}
                    end,
                    Result2 = case ContentType of
                        undefined -> Result1;
                        CT -> Result1#{content_type => CT}
                    end,
                    {ok, Result2}
            end
    end.

parse_headers(HeadersBin) ->
    Lines = binary:split(HeadersBin, <<"\r\n">>, [global]),
    lists:filtermap(
        fun(Line) ->
            case binary:match(Line, <<":">>) of
                nomatch -> false;
                {Pos, _} ->
                    Name = string:lowercase(string:trim(binary:part(Line, 0, Pos))),
                    Value = string:trim(binary:part(Line, Pos + 1, byte_size(Line) - Pos - 1)),
                    {true, {Name, Value}}
            end
        end,
        Lines
    ).

parse_disposition(Disposition) ->
    Parts = binary:split(Disposition, <<";">>, [global]),
    lists:foldl(
        fun(Part, Acc) ->
            Trimmed = string:trim(Part),
            case binary:match(Trimmed, <<"=">>) of
                nomatch -> Acc;
                {Pos, _} ->
                    Key = string:trim(binary:part(Trimmed, 0, Pos)),
                    Value = string:trim(binary:part(Trimmed, Pos + 1, byte_size(Trimmed) - Pos - 1)),
                    %% Remove quotes
                    CleanValue = case Value of
                        <<$", Rest/binary>> ->
                            case binary:last(Rest) of
                                $" -> binary:part(Rest, 0, byte_size(Rest) - 1);
                                _ -> Rest
                            end;
                        _ -> Value
                    end,
                    case Key of
                        <<"name">> -> Acc#{name => CleanValue};
                        <<"filename">> -> Acc#{filename => CleanValue};
                        _ -> Acc
                    end
            end
        end,
        #{},
        Parts
    ).

%%====================================================================
%% JSON Helpers
%%====================================================================

%% @doc Decode JSON body.
-spec json_body(#livery_req{}) -> {ok, term()} | {error, term()}.
json_body(Req) ->
    Body = livery_req:body(Req),
    case Body of
        undefined -> {error, no_body};
        <<>> -> {error, empty_body};
        _ ->
            try {ok, json:decode(Body)}
            catch
                error:Reason -> {error, {invalid_json, Reason}};
                _:Reason -> {error, Reason}
            end
    end.

%% @doc Reply with JSON response.
-spec reply_json(non_neg_integer(), term(), term()) ->
    {reply, non_neg_integer(), [{binary(), binary()}], iodata(), term()}.
reply_json(Status, Data, State) ->
    reply_json(Status, Data, [], State).

%% @doc Reply with JSON response and extra headers.
-spec reply_json(non_neg_integer(), term(), [{binary(), binary()}], term()) ->
    {reply, non_neg_integer(), [{binary(), binary()}], iodata(), term()}.
reply_json(Status, Data, ExtraHeaders, State) ->
    Body = json:encode(Data),
    Headers = [{<<"content-type">>, <<"application/json">>} | ExtraHeaders],
    {reply, Status, Headers, Body, State}.

%%====================================================================
%% Common Response Helpers
%%====================================================================

%% @doc Reply with plain text response.
-spec reply_text(non_neg_integer(), iodata(), term()) ->
    {reply, non_neg_integer(), [{binary(), binary()}], iodata(), term()}.
reply_text(Status, Text, State) ->
    {reply, Status, [{<<"content-type">>, <<"text/plain; charset=utf-8">>}], Text, State}.

%% @doc Reply with HTML response.
-spec reply_html(non_neg_integer(), iodata(), term()) ->
    {reply, non_neg_integer(), [{binary(), binary()}], iodata(), term()}.
reply_html(Status, Html, State) ->
    {reply, Status, [{<<"content-type">>, <<"text/html; charset=utf-8">>}], Html, State}.

%% @doc Reply with file contents.
-spec reply_file(non_neg_integer(), file:filename_all(), term()) ->
    {reply, non_neg_integer(), [{binary(), binary()}], binary(), term()} |
    {error, term(), term()}.
reply_file(Status, FilePath, State) ->
    case file:read_file(FilePath) of
        {ok, Content} ->
            ContentType = guess_content_type(FilePath),
            {reply, Status, [{<<"content-type">>, ContentType}], Content, State};
        {error, Reason} ->
            {error, {file_error, Reason}, State}
    end.

%% @doc Reply with 302 redirect.
-spec reply_redirect(binary(), term()) ->
    {reply, 302, [{binary(), binary()}], <<>>, term()}.
reply_redirect(Location, State) ->
    reply_redirect(302, Location, State).

%% @doc Reply with redirect using specific status code.
-spec reply_redirect(non_neg_integer(), binary(), term()) ->
    {reply, non_neg_integer(), [{binary(), binary()}], <<>>, term()}.
reply_redirect(Status, Location, State) ->
    {reply, Status, [{<<"location">>, Location}], <<>>, State}.

%% @doc Reply with 404 Not Found.
-spec reply_not_found(term()) ->
    {reply, 404, [{binary(), binary()}], binary(), term()}.
reply_not_found(State) ->
    reply_text(404, <<"Not Found">>, State).

%% @doc Reply with 400 Bad Request.
-spec reply_bad_request(iodata(), term()) ->
    {reply, 400, [{binary(), binary()}], iodata(), term()}.
reply_bad_request(Message, State) ->
    reply_text(400, Message, State).

%% @doc Reply with 500 Internal Server Error.
-spec reply_internal_error(iodata(), term()) ->
    {reply, 500, [{binary(), binary()}], iodata(), term()}.
reply_internal_error(Message, State) ->
    reply_text(500, Message, State).

%%====================================================================
%% Cookie Helpers
%%====================================================================

%% @doc Get cookie value from request.
-spec get_cookie(binary(), #livery_req{}) -> binary() | undefined.
get_cookie(Name, Req) ->
    get_cookie(Name, Req, undefined).

%% @doc Get cookie value with default.
-spec get_cookie(binary(), #livery_req{}, Default) -> binary() | Default
    when Default :: term().
get_cookie(Name, Req, Default) ->
    case livery_req:header(<<"cookie">>, Req) of
        undefined -> Default;
        CookieHeader ->
            Cookies = parse_cookies(CookieHeader),
            maps:get(Name, Cookies, Default)
    end.

%% @doc Create Set-Cookie header tuple.
-spec set_cookie(binary(), binary(), cookie_opts()) -> {binary(), binary()}.
set_cookie(Name, Value, Opts) ->
    Cookie = iolist_to_binary([
        Name, <<"=">>, Value,
        cookie_path(Opts),
        cookie_domain(Opts),
        cookie_max_age(Opts),
        cookie_secure(Opts),
        cookie_http_only(Opts),
        cookie_same_site(Opts)
    ]),
    {<<"set-cookie">>, Cookie}.

%% @doc Create Set-Cookie header to delete a cookie.
-spec delete_cookie(binary()) -> {binary(), binary()}.
delete_cookie(Name) ->
    set_cookie(Name, <<>>, #{max_age => 0}).

parse_cookies(CookieHeader) ->
    Parts = binary:split(CookieHeader, <<";">>, [global]),
    lists:foldl(
        fun(Part, Acc) ->
            Trimmed = string:trim(Part),
            case binary:match(Trimmed, <<"=">>) of
                nomatch -> Acc;
                {Pos, _} ->
                    Key = string:trim(binary:part(Trimmed, 0, Pos)),
                    Value = string:trim(binary:part(Trimmed, Pos + 1, byte_size(Trimmed) - Pos - 1)),
                    Acc#{Key => Value}
            end
        end,
        #{},
        Parts
    ).

cookie_path(#{path := Path}) -> <<"; Path=", Path/binary>>;
cookie_path(_) -> <<>>.

cookie_domain(#{domain := Domain}) -> <<"; Domain=", Domain/binary>>;
cookie_domain(_) -> <<>>.

cookie_max_age(#{max_age := MaxAge}) ->
    <<"; Max-Age=", (integer_to_binary(MaxAge))/binary>>;
cookie_max_age(_) -> <<>>.

cookie_secure(#{secure := true}) -> <<"; Secure">>;
cookie_secure(_) -> <<>>.

cookie_http_only(#{http_only := true}) -> <<"; HttpOnly">>;
cookie_http_only(_) -> <<>>.

cookie_same_site(#{same_site := strict}) -> <<"; SameSite=Strict">>;
cookie_same_site(#{same_site := lax}) -> <<"; SameSite=Lax">>;
cookie_same_site(#{same_site := none}) -> <<"; SameSite=None">>;
cookie_same_site(_) -> <<>>.

%%====================================================================
%% Path Bindings
%%====================================================================

%% @doc Get path binding from handler options.
-spec binding(binary(), term()) -> binary() | undefined.
binding(Name, Opts) ->
    binding(Name, Opts, undefined).

%% @doc Get path binding with default.
-spec binding(binary(), term(), Default) -> binary() | Default
    when Default :: term().
binding(Name, Opts, Default) when is_map(Opts) ->
    Bindings = maps:get(bindings, Opts, #{}),
    maps:get(Name, Bindings, Default);
binding(_Name, _Opts, Default) ->
    Default.

%% @doc Get all path bindings.
-spec bindings(term()) -> #{binary() => binary()}.
bindings(Opts) when is_map(Opts) ->
    maps:get(bindings, Opts, #{});
bindings(_Opts) ->
    #{}.

%%====================================================================
%% Content Negotiation
%%====================================================================

%% @doc Check if request accepts given content type.
-spec accepts(binary(), #livery_req{}) -> boolean().
accepts(ContentType, Req) ->
    case livery_req:accept(Req) of
        undefined -> true;  % No Accept header means accept anything
        Accept ->
            AcceptList = parse_accept(Accept),
            matches_accept(ContentType, AcceptList)
    end.

%% @doc Check if request accepts JSON.
-spec accepts_json(#livery_req{}) -> boolean().
accepts_json(Req) ->
    accepts(<<"application/json">>, Req).

%% @doc Check if request accepts HTML.
-spec accepts_html(#livery_req{}) -> boolean().
accepts_html(Req) ->
    accepts(<<"text/html">>, Req).

%% @doc Find preferred content type from list.
-spec preferred_type([binary()], #livery_req{}) -> binary() | undefined.
preferred_type(Types, Req) ->
    case livery_req:accept(Req) of
        undefined ->
            case Types of
                [First | _] -> First;
                [] -> undefined
            end;
        Accept ->
            AcceptList = parse_accept(Accept),
            find_preferred(Types, AcceptList)
    end.

parse_accept(Accept) ->
    Parts = binary:split(Accept, <<",">>, [global]),
    Parsed = lists:filtermap(
        fun(Part) ->
            Trimmed = string:trim(Part),
            case binary:match(Trimmed, <<";">>) of
                nomatch ->
                    {true, {Trimmed, 1.0}};
                {Pos, _} ->
                    Type = string:trim(binary:part(Trimmed, 0, Pos)),
                    Params = binary:part(Trimmed, Pos + 1, byte_size(Trimmed) - Pos - 1),
                    Q = parse_quality(Params),
                    {true, {Type, Q}}
            end
        end,
        Parts
    ),
    %% Sort by quality, descending
    lists:sort(fun({_, Q1}, {_, Q2}) -> Q1 >= Q2 end, Parsed).

parse_quality(Params) ->
    case binary:match(Params, <<"q=">>) of
        nomatch -> 1.0;
        {Pos, Len} ->
            QStart = Pos + Len,
            Rest = binary:part(Params, QStart, byte_size(Params) - QStart),
            QBin = case binary:match(Rest, <<";">>) of
                nomatch -> Rest;
                {EndPos, _} -> binary:part(Rest, 0, EndPos)
            end,
            try binary_to_float(QBin)
            catch _:_ ->
                try float(binary_to_integer(QBin))
                catch _:_ -> 1.0
                end
            end
    end.

matches_accept(ContentType, AcceptList) ->
    lists:any(
        fun({Accept, _Q}) ->
            Accept =:= <<"*/*">> orelse
            Accept =:= ContentType orelse
            matches_type_wildcard(ContentType, Accept)
        end,
        AcceptList
    ).

matches_type_wildcard(ContentType, Accept) ->
    case binary:match(Accept, <<"/*">>) of
        nomatch -> false;
        {Pos, _} ->
            TypePrefix = binary:part(Accept, 0, Pos + 1),
            binary:match(ContentType, TypePrefix) =:= {0, Pos + 1}
    end.

find_preferred(Types, AcceptList) ->
    %% Find first type that matches highest quality accept
    find_preferred_loop(AcceptList, Types).

find_preferred_loop([], _Types) ->
    undefined;
find_preferred_loop([{Accept, _Q} | Rest], Types) ->
    case find_matching_type(Accept, Types) of
        undefined -> find_preferred_loop(Rest, Types);
        Type -> Type
    end.

find_matching_type(_Accept, []) ->
    undefined;
find_matching_type(Accept, [Type | Rest]) ->
    case Accept =:= <<"*/*">> orelse Accept =:= Type orelse matches_type_wildcard(Type, Accept) of
        true -> Type;
        false -> find_matching_type(Accept, Rest)
    end.

%%====================================================================
%% Internal
%%====================================================================

guess_content_type(FilePath) ->
    Ext = filename:extension(FilePath),
    case string:lowercase(Ext) of
        <<".html">> -> <<"text/html; charset=utf-8">>;
        ".html" -> <<"text/html; charset=utf-8">>;
        <<".htm">> -> <<"text/html; charset=utf-8">>;
        ".htm" -> <<"text/html; charset=utf-8">>;
        <<".css">> -> <<"text/css; charset=utf-8">>;
        ".css" -> <<"text/css; charset=utf-8">>;
        <<".js">> -> <<"application/javascript; charset=utf-8">>;
        ".js" -> <<"application/javascript; charset=utf-8">>;
        <<".json">> -> <<"application/json">>;
        ".json" -> <<"application/json">>;
        <<".xml">> -> <<"application/xml">>;
        ".xml" -> <<"application/xml">>;
        <<".txt">> -> <<"text/plain; charset=utf-8">>;
        ".txt" -> <<"text/plain; charset=utf-8">>;
        <<".png">> -> <<"image/png">>;
        ".png" -> <<"image/png">>;
        <<".jpg">> -> <<"image/jpeg">>;
        ".jpg" -> <<"image/jpeg">>;
        <<".jpeg">> -> <<"image/jpeg">>;
        ".jpeg" -> <<"image/jpeg">>;
        <<".gif">> -> <<"image/gif">>;
        ".gif" -> <<"image/gif">>;
        <<".svg">> -> <<"image/svg+xml">>;
        ".svg" -> <<"image/svg+xml">>;
        <<".ico">> -> <<"image/x-icon">>;
        ".ico" -> <<"image/x-icon">>;
        <<".pdf">> -> <<"application/pdf">>;
        ".pdf" -> <<"application/pdf">>;
        <<".woff">> -> <<"font/woff">>;
        ".woff" -> <<"font/woff">>;
        <<".woff2">> -> <<"font/woff2">>;
        ".woff2" -> <<"font/woff2">>;
        _ -> <<"application/octet-stream">>
    end.
