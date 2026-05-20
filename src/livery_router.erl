-module(livery_router).
-moduledoc """
Radix-style path-segment router.

Routes are compiled into an immutable trie. Each segment of a
pattern is one of:

- static, e.g. `users` in `/users/new`;
- parameter, prefixed with `:`, e.g. `:id` in `/users/:id`;
- wildcard, prefixed with `*`, e.g. `*path` in `/files/*path`,
  matching all remaining segments joined back with `/`.

`match/3` returns `{ok, Handler, Bindings, Meta}` on a
method-aware hit, `{error, {method_not_allowed, Methods}}` when
the path matches but no route is registered for the requested
method, or `{error, not_found}` otherwise.
""".

-export([
    new/0,
    add/5,
    compile/1,
    match/3
]).

-export_type([router/0, handler/0, pattern/0, method/0, meta/0]).

-type method() :: binary() | '_'.
-type pattern() :: binary().
-type handler() :: term().
-type meta() :: term().
-type bindings() :: #{binary() => binary()}.

-record(node, {
    static   = #{}       :: #{binary() => #node{}},
    param    = undefined :: undefined | {binary(), #node{}},
    wildcard = undefined :: undefined | {binary(), handlers()},
    handlers = #{}       :: handlers()
}).

-type handlers() :: #{method() => {handler(), meta()}}.

-opaque router() :: #node{}.

%%====================================================================
%% Public API
%%====================================================================

-doc "Empty router with no routes.".
-spec new() -> router().
new() -> #node{}.

-doc """
Insert one route.

Method may be `'_'` to match any HTTP method. Later additions with
the same Method+Pattern replace the previous entry.
""".
-spec add(method(), pattern(), handler(), meta(), router()) -> router().
add(Method, Pattern, Handler, Meta, Router) ->
    Segments = split(Pattern),
    insert(Segments, Method, Handler, Meta, Router).

-doc "Build a router from a list of routes in one shot.".
-spec compile([{method(), pattern(), handler()} |
               {method(), pattern(), handler(), meta()}]) -> router().
compile(Routes) ->
    lists:foldl(
        fun
            ({Method, Pattern, Handler}, Acc) ->
                add(Method, Pattern, Handler, undefined, Acc);
            ({Method, Pattern, Handler, Meta}, Acc) ->
                add(Method, Pattern, Handler, Meta, Acc)
        end,
        new(),
        Routes
    ).

-doc "Look up a route by method and path.".
-spec match(method(), binary(), router()) ->
    {ok, handler(), bindings(), meta()}
  | {error, not_found}
  | {error, {method_not_allowed, [method()]}}.
match(Method, Path, Router) ->
    Segments = split(Path),
    case walk(Segments, Router, #{}) of
        {match, Handlers, Bindings} ->
            pick_handler(Method, Handlers, Bindings);
        nomatch ->
            {error, not_found}
    end.

%%====================================================================
%% Insertion
%%====================================================================

-spec insert([binary()], method(), handler(), meta(), #node{}) -> #node{}.
insert([], Method, Handler, Meta, Node = #node{handlers = Hs}) ->
    Node#node{handlers = maps:put(Method, {Handler, Meta}, Hs)};
insert([Segment | Rest], Method, Handler, Meta, Node) ->
    case classify(Segment) of
        {static, S} ->
            Children = Node#node.static,
            Child = maps:get(S, Children, #node{}),
            Child1 = insert(Rest, Method, Handler, Meta, Child),
            Node#node{static = maps:put(S, Child1, Children)};
        {param, Name} ->
            Existing = case Node#node.param of
                undefined -> {Name, #node{}};
                {PrevName, _} when PrevName =/= Name ->
                    error({conflicting_param, PrevName, Name});
                Other ->
                    Other
            end,
            {N, ChildNode} = Existing,
            ChildNode1 = insert(Rest, Method, Handler, Meta, ChildNode),
            Node#node{param = {N, ChildNode1}};
        {wildcard, Name} ->
            [] =:= Rest orelse error({wildcard_must_be_last, Segment}),
            Hs0 = case Node#node.wildcard of
                undefined -> #{};
                {PrevName, _} when PrevName =/= Name ->
                    error({conflicting_wildcard, PrevName, Name});
                {_, M} -> M
            end,
            Node#node{wildcard = {Name, maps:put(Method, {Handler, Meta}, Hs0)}}
    end.

%%====================================================================
%% Matching
%%====================================================================

-spec walk([binary()], #node{}, bindings()) ->
    {match, handlers(), bindings()} | nomatch.
walk([], #node{handlers = Hs}, Bindings) when map_size(Hs) > 0 ->
    {match, Hs, Bindings};
walk([], #node{wildcard = {Name, Hs}}, Bindings) when map_size(Hs) > 0 ->
    {match, Hs, maps:put(Name, <<>>, Bindings)};
walk([], _Node, _Bindings) ->
    nomatch;
walk(Segments = [Seg | Rest], Node, Bindings) ->
    case try_static(Seg, Rest, Node, Bindings) of
        {match, _, _} = M -> M;
        nomatch ->
            case try_param(Seg, Rest, Node, Bindings) of
                {match, _, _} = M -> M;
                nomatch -> try_wildcard(Segments, Node, Bindings)
            end
    end.

-spec try_static(binary(), [binary()], #node{}, bindings()) ->
    {match, handlers(), bindings()} | nomatch.
try_static(Seg, Rest, #node{static = Children}, Bindings) ->
    case maps:find(Seg, Children) of
        {ok, Child} -> walk(Rest, Child, Bindings);
        error       -> nomatch
    end.

-spec try_param(binary(), [binary()], #node{}, bindings()) ->
    {match, handlers(), bindings()} | nomatch.
try_param(_Seg, _Rest, #node{param = undefined}, _Bindings) ->
    nomatch;
try_param(Seg, Rest, #node{param = {Name, Child}}, Bindings) ->
    walk(Rest, Child, maps:put(Name, Seg, Bindings)).

-spec try_wildcard([binary()], #node{}, bindings()) ->
    {match, handlers(), bindings()} | nomatch.
try_wildcard(_Segments, #node{wildcard = undefined}, _Bindings) ->
    nomatch;
try_wildcard(Segments, #node{wildcard = {Name, Hs}}, Bindings) ->
    {match, Hs, maps:put(Name, join(Segments), Bindings)}.

-spec pick_handler(method(), handlers(), bindings()) ->
    {ok, handler(), bindings(), meta()}
  | {error, {method_not_allowed, [method()]}}.
pick_handler(Method, Handlers, Bindings) ->
    case maps:find(Method, Handlers) of
        {ok, {H, Meta}} ->
            {ok, H, Bindings, Meta};
        error ->
            case maps:find('_', Handlers) of
                {ok, {H, Meta}} ->
                    {ok, H, Bindings, Meta};
                error ->
                    {error, {method_not_allowed, lists:sort(maps:keys(Handlers))}}
            end
    end.

%%====================================================================
%% Helpers
%%====================================================================

-spec split(binary()) -> [binary()].
split(<<$/, Rest/binary>>) -> split(Rest);
split(Path) when is_binary(Path) ->
    %% Drop query fragment if present (router only sees the path).
    Path1 = case binary:split(Path, <<"?">>) of
        [P, _]  -> P;
        [P]     -> P
    end,
    case Path1 of
        <<>> -> [];
        _    -> binary:split(Path1, <<"/">>, [global])
    end.

-spec join([binary(), ...]) -> binary().
join([S])  -> S;
join(Segs) -> iolist_to_binary(lists:join(<<"/">>, Segs)).

-spec classify(binary()) -> {static, binary()} | {param, binary()} | {wildcard, binary()}.
classify(<<$:, Name/binary>>) when byte_size(Name) > 0 -> {param, Name};
classify(<<$*, Name/binary>>) when byte_size(Name) > 0 -> {wildcard, Name};
classify(Seg)                                           -> {static, Seg}.
