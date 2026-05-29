%% @doc Documentation guard.
%%
%% Keeps the `docs/' tree honest about the code it describes:
%%
%% - `snippets_compile' extracts every standalone module from an
%%   ```erlang fenced block (one carrying `-module(...)') and compiles
%%   it, so a snippet that no longer builds fails the suite.
%% - `snippets_calls_exist' scans every fenced block for
%%   `livery_*:fn(...)' calls and asserts each one is exported at the
%%   arity used, so a doc can never reference a function that does not
%%   exist (the arity is checked for calls whose argument list is
%%   balanced; otherwise the name is checked at any arity).
%%
%% Comments and `-spec'/`-type' lines are stripped before scanning so
%% type references like `livery_req:req()' are not mistaken for calls.
-module(livery_docs_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    snippets_compile/1,
    snippets_calls_exist/1
]).

all() ->
    [snippets_compile, snippets_calls_exist].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery),
    Dir = docs_dir(),
    true = filelib:is_dir(Dir),
    [{docs_dir, Dir} | Config].

end_per_suite(_Config) ->
    ok.

%%====================================================================
%% Cases
%%====================================================================

snippets_compile(Config) ->
    Tmp = ?config(priv_dir, Config),
    Blocks = [B || {_F, B} <- all_blocks(Config), is_module_block(B)],
    Failures = lists:filtermap(fun(B) -> compile_block(B, Tmp) end, Blocks),
    case Failures of
        [] -> ok;
        _ -> ct:fail({snippet_compile_failures, Failures})
    end.

snippets_calls_exist(Config) ->
    Calls = lists:flatmap(
        fun({F, B}) -> calls_in(F, B) end,
        all_blocks(Config)
    ),
    Bad = lists:usort([C || C <- Calls, not call_ok(C)]),
    case Bad of
        [] -> ok;
        _ -> ct:fail({unknown_doc_calls, Bad})
    end.

%%====================================================================
%% Doc discovery
%%====================================================================

docs_dir() ->
    Lib = code:lib_dir(livery),
    Candidates = [
        filename:join(Lib, "docs"),
        filename:join([Lib, "..", "..", "..", "..", "docs"])
    ],
    case [D || D <- Candidates, filelib:is_dir(D)] of
        [Dir | _] -> Dir;
        [] -> filename:join(Lib, "docs")
    end.

all_blocks(Config) ->
    Dir = ?config(docs_dir, Config),
    Files = filelib:wildcard(filename:join(Dir, "**/*.md")),
    lists:flatmap(
        fun(F) ->
            {ok, Bin} = file:read_file(F),
            [{F, B} || B <- erlang_blocks(Bin)]
        end,
        Files
    ).

erlang_blocks(Bin) ->
    RE = "```erlang\\s*?\\n(.*?)```",
    case re:run(Bin, RE, [global, dotall, {capture, all_but_first, binary}]) of
        {match, Groups} -> [B || [B] <- Groups];
        nomatch -> []
    end.

is_module_block(B) ->
    binary:match(B, <<"-module(">>) =/= nomatch.

%%====================================================================
%% Compile check
%%====================================================================

compile_block(Bin, Tmp) ->
    Mod = module_name(Bin),
    File = filename:join(Tmp, Mod ++ ".erl"),
    ok = file:write_file(File, Bin),
    Res = compile:file(File, [binary, return_errors, return_warnings]),
    case Res of
        {ok, _M} -> false;
        {ok, _M, _Ws} -> false;
        {ok, _M, _Bin, _Ws} -> false;
        {error, Errors, _Ws} -> {true, {list_to_atom(Mod), Errors}};
        error -> {true, {list_to_atom(Mod), compile_failed}}
    end.

module_name(Bin) ->
    {match, [Name]} = re:run(
        Bin,
        "-module\\(\\s*([a-z_][a-zA-Z0-9_]*)\\s*\\)",
        [{capture, all_but_first, list}]
    ),
    Name.

%%====================================================================
%% Call-existence check
%%====================================================================

calls_in(File, Bin) ->
    Code = strip_specs(strip_comments(Bin)),
    RE = "(livery[a-zA-Z0-9_]*):([a-z_][a-zA-Z0-9_]*)\\(",
    case re:run(Code, RE, [global, {capture, [0, 1, 2], index}]) of
        nomatch ->
            [];
        {match, Matches} ->
            [
                {filename:basename(File), Mod, Fn, arity_after(Code, S0 + L0)}
             || [{S0, L0}, {S1, L1}, {S2, L2}] <- Matches,
                Mod <- [binary_to_list(binary:part(Code, S1, L1))],
                Fn <- [binary_to_list(binary:part(Code, S2, L2))]
            ]
    end.

call_ok({_File, Mod, Fn, Arity}) ->
    try
        ModA = list_to_existing_atom(Mod),
        FnA = list_to_existing_atom(Fn),
        _ = code:ensure_loaded(ModA),
        Exports = ModA:module_info(exports),
        case Arity of
            any -> lists:keymember(FnA, 1, Exports);
            N -> lists:member({FnA, N}, Exports)
        end
    catch
        error:badarg -> false;
        error:undef -> false
    end.

%% Arity of the call whose argument list opens at `Start' (just after
%% the `('). Find the matching `)', then count top-level commas in the
%% span. A span containing `->' or `||' holds a `fun'/`case'/`if'/
%% comprehension whose internal commas cannot be counted by bracket
%% depth alone, so fall back to `any' (name-only existence). `any' is
%% also returned when the list does not close inside the block.
arity_after(Bin, Start) ->
    Len = byte_size(Bin),
    case find_close(Bin, Start, Len, 0) of
        no_close ->
            any;
        End ->
            Span = binary:part(Bin, Start, End - Start),
            case binary:match(Span, [<<"->">>, <<"||">>]) of
                nomatch -> count_args(Span);
                _ -> any
            end
    end.

find_close(_Bin, Pos, Len, _Depth) when Pos >= Len -> no_close;
find_close(Bin, Pos, Len, Depth) ->
    case binary:at(Bin, Pos) of
        $" ->
            find_close_str(Bin, Pos + 1, Len, Depth);
        $$ ->
            find_close(Bin, Pos + 2, Len, Depth);
        $) when Depth =:= 0 -> Pos;
        C when C =:= $(; C =:= $[; C =:= ${ ->
            find_close(Bin, Pos + 1, Len, Depth + 1);
        C when C =:= $); C =:= $]; C =:= $} ->
            find_close(Bin, Pos + 1, Len, Depth - 1);
        _ ->
            find_close(Bin, Pos + 1, Len, Depth)
    end.

find_close_str(_Bin, Pos, Len, _Depth) when Pos >= Len -> no_close;
find_close_str(Bin, Pos, Len, Depth) ->
    case binary:at(Bin, Pos) of
        $\\ -> find_close_str(Bin, Pos + 2, Len, Depth);
        $" -> find_close(Bin, Pos + 1, Len, Depth);
        _ -> find_close_str(Bin, Pos + 1, Len, Depth)
    end.

count_args(Span) ->
    case string:trim(Span) of
        <<>> -> 0;
        _ -> count_commas(Span, 0, byte_size(Span), 0, 1)
    end.

count_commas(_S, Pos, Len, _Depth, N) when Pos >= Len -> N;
count_commas(S, Pos, Len, Depth, N) ->
    case binary:at(S, Pos) of
        $" ->
            count_in_str(S, Pos + 1, Len, Depth, N);
        $$ ->
            count_commas(S, Pos + 2, Len, Depth, N);
        C when C =:= $(; C =:= $[; C =:= ${ ->
            count_commas(S, Pos + 1, Len, Depth + 1, N);
        C when C =:= $); C =:= $]; C =:= $} ->
            count_commas(S, Pos + 1, Len, Depth - 1, N);
        $, when Depth =:= 0 -> count_commas(S, Pos + 1, Len, Depth, N + 1);
        _ ->
            count_commas(S, Pos + 1, Len, Depth, N)
    end.

count_in_str(_S, Pos, Len, _Depth, N) when Pos >= Len -> N;
count_in_str(S, Pos, Len, Depth, N) ->
    case binary:at(S, Pos) of
        $\\ -> count_in_str(S, Pos + 2, Len, Depth, N);
        $" -> count_commas(S, Pos + 1, Len, Depth, N);
        _ -> count_in_str(S, Pos + 1, Len, Depth, N)
    end.

%%====================================================================
%% Comment / spec stripping
%%====================================================================

strip_comments(Bin) ->
    iolist_to_binary(strip_comments(Bin, 0, byte_size(Bin), false, [])).

strip_comments(_Bin, Pos, Len, _InStr, Acc) when Pos >= Len ->
    lists:reverse(Acc);
strip_comments(Bin, Pos, Len, InStr, Acc) ->
    case binary:at(Bin, Pos) of
        $" ->
            strip_comments(Bin, Pos + 1, Len, not InStr, [$" | Acc]);
        $\\ when InStr ->
            Next = next_byte(Bin, Pos + 1, Len),
            strip_comments(Bin, Pos + 2, Len, InStr, Next ++ [$\\ | Acc]);
        $% when not InStr -> strip_comments(Bin, skip_to_eol(Bin, Pos, Len), Len, InStr, Acc);
        C ->
            strip_comments(Bin, Pos + 1, Len, InStr, [C | Acc])
    end.

next_byte(_Bin, Pos, Len) when Pos >= Len -> [];
next_byte(Bin, Pos, _Len) -> [binary:at(Bin, Pos)].

skip_to_eol(_Bin, Pos, Len) when Pos >= Len -> Len;
skip_to_eol(Bin, Pos, Len) ->
    case binary:at(Bin, Pos) of
        $\n -> Pos;
        _ -> skip_to_eol(Bin, Pos + 1, Len)
    end.

%% Drop single-line -spec / -type attribute lines (the snippets carry
%% no multi-line specs).
strip_specs(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    Kept = [L || L <- Lines, not is_spec_line(L)],
    iolist_to_binary(lists:join(<<"\n">>, Kept)).

is_spec_line(L) ->
    T = string:trim(L, leading),
    lists:any(
        fun(P) -> binary:longest_common_prefix([T, P]) =:= byte_size(P) end,
        [<<"-spec ">>, <<"-spec(">>, <<"-type ">>, <<"-type(">>]
    ).
