-module(livery_auth_totp).
-moduledoc """
Time-based one-time passwords (RFC 6238), for a second sign-in factor.

The six-digit codes authenticator apps show. You keep one secret per
user; `verify/3` checks a code against it.

```erlang
%% Enrolment: show the URI as a QR code, then confirm a first code.
Secret = livery_auth_totp:secret(),
Uri = livery_auth_totp:uri(Secret, #{issuer => <<"Acme">>, account => <<"alice@example.org">>}),
{ok, Step} = livery_auth_totp:verify(Code, Secret, #{}),

%% Sign-in: refuse a code that was already used.
case livery_auth_totp:verify(Code, Secret, #{last_step => LastStep}) of
    {ok, NewStep} -> store_last_step(User, NewStep), ok;
    error -> refused
end.
```

`verify/3` accepts the code for the current 30-second step and for
`window` steps either side (default 1), to allow for clock drift, and
refuses any step not later than `last_step`, so a code cannot be used
twice. Store the step it returns. Options for both `code/2` and
`verify/3`: `algorithm` (`sha1` default, `sha256`, `sha512`), `digits`
(6 or 8, default 6), `period` (seconds, default 30), `now` (Unix
seconds).

Secrets, the last step and rate limiting belong to your application:
put `livery_ratelimit` in front of the route that checks codes. TOTP
is not phishing-resistant: a fake sign-in page can relay a code while
it is valid.
""".

-export([secret/0, encode/1, decode/1, uri/2, code/2, verify/3]).

-define(B32, <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567">>).

-type opts() :: #{
    algorithm => sha1 | sha256 | sha512,
    digits => 6 | 8,
    period => pos_integer(),
    window => non_neg_integer(),
    last_step => integer(),
    now => integer()
}.

-export_type([opts/0]).

-doc "A new random secret of 160 bits, the length RFC 4226 recommends.".
-spec secret() -> binary().
secret() ->
    crypto:strong_rand_bytes(20).

-doc "Base32 without padding (RFC 4648), the form authenticator apps take.".
-spec encode(binary()) -> binary().
encode(Bin) ->
    Pad = (5 - bit_size(Bin) rem 5) rem 5,
    <<<<(binary:at(?B32, C))>> || <<C:5>> <= <<Bin/binary, 0:Pad>>>>.

-doc "Decode base32, ignoring case, spaces and padding.".
-spec decode(binary()) -> {ok, binary()} | error.
decode(Text) ->
    Chars = [C || <<C>> <= string:uppercase(Text), C =/= $\s, C =/= $=],
    case lists:all(fun(C) -> binary:match(?B32, <<C>>) =/= nomatch end, Chars) of
        true ->
            Bits = <<<<(index(C)):5>> || C <- Chars>>,
            Whole = bit_size(Bits) div 8 * 8,
            <<Bytes:Whole/bitstring, _/bitstring>> = Bits,
            {ok, Bytes};
        false ->
            error
    end.

-doc """
The `otpauth://totp/` URI to show as a QR code, with `issuer` and
`account` (both required). Non-default `algorithm`, `digits` and
`period` are included.
""".
-spec uri(binary(), #{issuer := binary(), account := binary(), atom() => term()}) -> binary().
uri(Secret, #{issuer := Issuer, account := Account} = Opts) ->
    Label = uri_string:quote(<<Issuer/binary, ":", Account/binary>>),
    Params =
        [{<<"secret">>, encode(Secret)}, {<<"issuer">>, Issuer}] ++
            [
                {<<"algorithm">>, string:uppercase(atom_to_binary(A))}
             || A <- [algorithm(Opts)], A =/= sha1
            ] ++
            [{<<"digits">>, integer_to_binary(D)} || D <- [digits(Opts)], D =/= 6] ++
            [{<<"period">>, integer_to_binary(P)} || P <- [period(Opts)], P =/= 30],
    iolist_to_binary([<<"otpauth://totp/">>, Label, $?, uri_string:compose_query(Params)]).

-doc "The code for the current step.".
-spec code(binary(), opts()) -> binary().
code(Secret, Opts) ->
    code_at(Secret, step(Opts), Opts).

-doc """
Check `Code` against `Secret`. Returns the step it matched, which must be
stored as `last_step` for the next check, or `error`.
""".
-spec verify(binary(), binary(), opts()) -> {ok, integer()} | error.
verify(Code, Secret, Opts) when is_binary(Code) ->
    Digits = digits(Opts),
    case
        byte_size(Code) =:= Digits andalso
            lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Code))
    of
        true -> match(Code, Secret, Opts);
        false -> error
    end;
verify(_Code, _Secret, _Opts) ->
    error.

match(Code, Secret, Opts) ->
    Now = step(Opts),
    Window = maps:get(window, Opts, 1),
    Last = maps:get(last_step, Opts, -1),
    %% Every candidate is computed and compared, so the time taken does
    %% not say which step matched.
    Matches = [
        S
     || S <- lists:seq(Now - Window, Now + Window),
        S > Last,
        crypto:hash_equals(code_at(Secret, S, Opts), Code)
    ],
    case Matches of
        [] -> error;
        _ -> {ok, lists:max(Matches)}
    end.

%%====================================================================
%% HOTP (RFC 4226 5.3)
%%====================================================================

code_at(Secret, Step, Opts) ->
    Mac = crypto:mac(hmac, digest(algorithm(Opts)), Secret, <<Step:64>>),
    Offset = binary:last(Mac) band 16#0f,
    <<_:Offset/binary, Bin:32, _/binary>> = Mac,
    Digits = digits(Opts),
    N = (Bin band 16#7fffffff) rem pow10(Digits),
    iolist_to_binary(io_lib:format("~*..0B", [Digits, N])).

step(Opts) ->
    maps:get(now, Opts, os:system_time(second)) div period(Opts).

algorithm(Opts) -> maps:get(algorithm, Opts, sha1).

%% OTP names SHA-1 `sha'.
digest(sha1) -> sha;
digest(Alg) -> Alg.
digits(Opts) -> maps:get(digits, Opts, 6).
period(Opts) -> maps:get(period, Opts, 30).

pow10(6) -> 1000000;
pow10(8) -> 100000000.

index(C) ->
    {Pos, 1} = binary:match(?B32, <<C>>),
    Pos.
