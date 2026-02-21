%% @doc Response builder for HTTP responses.
-module(livery_resp).

-export([
    build/4,
    build/3,
    status_text/1
]).

-spec build(non_neg_integer(), [{binary(), binary()}], iodata(), {non_neg_integer(), non_neg_integer()}) -> iodata().
build(Status, Headers, Body, Version) ->
    StatusLine = status_line(Status, Version),
    BodyBin = iolist_to_binary(Body),
    BodyLen = byte_size(BodyBin),
    AllHeaders = maybe_add_content_length(Headers, BodyLen),
    HeadersBin = encode_headers(AllHeaders),
    [StatusLine, HeadersBin, <<"\r\n">>, BodyBin].

-spec build(non_neg_integer(), [{binary(), binary()}], {non_neg_integer(), non_neg_integer()}) -> iodata().
build(Status, Headers, Version) ->
    StatusLine = status_line(Status, Version),
    HeadersBin = encode_headers(Headers),
    [StatusLine, HeadersBin, <<"\r\n">>].

-spec status_line(non_neg_integer(), {non_neg_integer(), non_neg_integer()}) -> binary().
status_line(Status, {Major, Minor}) ->
    StatusBin = integer_to_binary(Status),
    Text = status_text(Status),
    <<"HTTP/", (integer_to_binary(Major))/binary, ".", (integer_to_binary(Minor))/binary,
      " ", StatusBin/binary, " ", Text/binary, "\r\n">>.

-spec encode_headers([{binary(), binary()}]) -> iodata().
encode_headers(Headers) ->
    [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- Headers].

-spec maybe_add_content_length([{binary(), binary()}], non_neg_integer()) -> [{binary(), binary()}].
maybe_add_content_length(Headers, BodyLen) ->
    case has_content_length(Headers) of
        true -> Headers;
        false -> [{<<"content-length">>, integer_to_binary(BodyLen)} | Headers]
    end.

-spec has_content_length([{binary(), binary()}]) -> boolean().
has_content_length(Headers) ->
    lists:any(fun({Name, _}) ->
        string:lowercase(Name) =:= <<"content-length">>
    end, Headers).

-spec status_text(non_neg_integer()) -> binary().
status_text(100) -> <<"Continue">>;
status_text(101) -> <<"Switching Protocols">>;
status_text(200) -> <<"OK">>;
status_text(201) -> <<"Created">>;
status_text(202) -> <<"Accepted">>;
status_text(204) -> <<"No Content">>;
status_text(206) -> <<"Partial Content">>;
status_text(301) -> <<"Moved Permanently">>;
status_text(302) -> <<"Found">>;
status_text(303) -> <<"See Other">>;
status_text(304) -> <<"Not Modified">>;
status_text(307) -> <<"Temporary Redirect">>;
status_text(308) -> <<"Permanent Redirect">>;
status_text(400) -> <<"Bad Request">>;
status_text(401) -> <<"Unauthorized">>;
status_text(403) -> <<"Forbidden">>;
status_text(404) -> <<"Not Found">>;
status_text(405) -> <<"Method Not Allowed">>;
status_text(408) -> <<"Request Timeout">>;
status_text(411) -> <<"Length Required">>;
status_text(413) -> <<"Payload Too Large">>;
status_text(414) -> <<"URI Too Long">>;
status_text(415) -> <<"Unsupported Media Type">>;
status_text(416) -> <<"Range Not Satisfiable">>;
status_text(417) -> <<"Expectation Failed">>;
status_text(426) -> <<"Upgrade Required">>;
status_text(500) -> <<"Internal Server Error">>;
status_text(501) -> <<"Not Implemented">>;
status_text(502) -> <<"Bad Gateway">>;
status_text(503) -> <<"Service Unavailable">>;
status_text(504) -> <<"Gateway Timeout">>;
status_text(505) -> <<"HTTP Version Not Supported">>;
status_text(_) -> <<"Unknown">>.
