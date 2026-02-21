%% @doc HTTP router with prefix tree matching.
%%
%% Supports:
%% - Static path segments: /users/list
%% - Dynamic segments: /users/:id
%% - Wildcard segments: /files/*path
%% - Method-based routing: {get, "/users/:id", Handler, Opts}
%%
%% Example:
%% ```
%% Routes = [
%%     {get, "/", home_handler, []},
%%     {get, "/users", users_list_handler, []},
%%     {get, "/users/:id", user_handler, []},
%%     {post, "/users", user_create_handler, []},
%%     {'_', "/api/*path", api_handler, []}
%% ],
%% Router = livery_router:compile(Routes),
%% {ok, Handler, Opts, Bindings} = livery_router:match(Router, <<"GET">>, <<"/users/123">>).
%% '''
-module(livery_router).

-export([
    compile/1,
    match/3,
    add_route/2,
    remove_route/2
]).

-type method() :: get | post | put | delete | patch | head | options | connect | trace | '_'.

-record(trie_node, {
    handler :: {module(), term()} | undefined,
    children = #{} :: #{binary() => #trie_node{}},
    param_child :: {binary(), #trie_node{}} | undefined,  %% :name
    wildcard_child :: {binary(), #trie_node{}} | undefined  %% *name
}).

-record(router, {
    routes = #{} :: #{method() => #trie_node{}}
}).

-type route() :: {method(), binary() | string(), module(), term()}.
-type router() :: #router{}.
-type bindings() :: #{binary() => binary()}.

-export_type([router/0, route/0, bindings/0]).

%%====================================================================
%% API
%%====================================================================

%% @doc Compile a list of routes into a router.
-spec compile([route()]) -> router().
compile(Routes) ->
    lists:foldl(fun add_route/2, #router{}, Routes).

%% @doc Add a route to the router.
-spec add_route(route(), router()) -> router().
add_route({Method, Path, Handler, Opts}, #router{routes = Routes} = Router) ->
    PathBin = ensure_binary(Path),
    Segments = split_path(PathBin),
    MethodAtom = normalize_method(Method),

    %% Get or create trie for this method
    Trie = maps:get(MethodAtom, Routes, #trie_node{}),
    NewTrie = insert_route(Segments, {Handler, Opts}, Trie),

    Router#router{routes = Routes#{MethodAtom => NewTrie}}.

%% @doc Remove a route from the router.
-spec remove_route({method(), binary() | string()}, router()) -> router().
remove_route({Method, Path}, #router{routes = Routes} = Router) ->
    PathBin = ensure_binary(Path),
    Segments = split_path(PathBin),
    MethodAtom = normalize_method(Method),

    case maps:find(MethodAtom, Routes) of
        {ok, Trie} ->
            NewTrie = delete_route(Segments, Trie),
            Router#router{routes = Routes#{MethodAtom => NewTrie}};
        error ->
            Router
    end.

%% @doc Match a request against the router.
%% Returns {ok, Handler, Opts, Bindings} | {error, not_found}.
-spec match(router(), binary(), binary()) ->
    {ok, module(), term(), bindings()} | {error, not_found | method_not_allowed}.
match(#router{routes = Routes}, Method, Path) ->
    MethodAtom = normalize_method(Method),
    Segments = split_path(Path),

    %% Try exact method match first
    case maps:find(MethodAtom, Routes) of
        {ok, Trie} ->
            case match_trie(Segments, Trie, #{}) of
                {ok, Handler, Opts, Bindings} ->
                    {ok, Handler, Opts, Bindings};
                {error, not_found} ->
                    %% Try wildcard method
                    try_wildcard_method(Routes, Segments)
            end;
        error ->
            %% Try wildcard method
            try_wildcard_method(Routes, Segments)
    end.

try_wildcard_method(Routes, Segments) ->
    case maps:find('_', Routes) of
        {ok, Trie} ->
            match_trie(Segments, Trie, #{});
        error ->
            {error, not_found}
    end.

%%====================================================================
%% Internal - Trie operations
%%====================================================================

insert_route([], HandlerOpts, #trie_node{} = Node) ->
    Node#trie_node{handler = HandlerOpts};
insert_route([<<$:, Name/binary>> | Rest], HandlerOpts, #trie_node{param_child = PC} = Node) ->
    %% Parameter segment
    ChildNode = case PC of
        undefined -> #trie_node{};
        {_, Existing} -> Existing
    end,
    NewChild = insert_route(Rest, HandlerOpts, ChildNode),
    Node#trie_node{param_child = {Name, NewChild}};
insert_route([<<$*, Name/binary>> | _Rest], HandlerOpts, #trie_node{} = Node) ->
    %% Wildcard segment (captures rest of path)
    WildcardNode = #trie_node{handler = HandlerOpts},
    Node#trie_node{wildcard_child = {Name, WildcardNode}};
insert_route([Segment | Rest], HandlerOpts, #trie_node{children = Children} = Node) ->
    %% Static segment
    ChildNode = maps:get(Segment, Children, #trie_node{}),
    NewChild = insert_route(Rest, HandlerOpts, ChildNode),
    Node#trie_node{children = Children#{Segment => NewChild}}.

delete_route([], #trie_node{} = Node) ->
    Node#trie_node{handler = undefined};
delete_route([<<$:, _Name/binary>> | Rest], #trie_node{param_child = PC} = Node) ->
    case PC of
        undefined -> Node;
        {Name, ChildNode} ->
            NewChild = delete_route(Rest, ChildNode),
            Node#trie_node{param_child = {Name, NewChild}}
    end;
delete_route([<<$*, _Name/binary>> | _Rest], #trie_node{} = Node) ->
    Node#trie_node{wildcard_child = undefined};
delete_route([Segment | Rest], #trie_node{children = Children} = Node) ->
    case maps:find(Segment, Children) of
        {ok, ChildNode} ->
            NewChild = delete_route(Rest, ChildNode),
            Node#trie_node{children = Children#{Segment => NewChild}};
        error ->
            Node
    end.

match_trie([], #trie_node{handler = {Handler, Opts}}, Bindings) ->
    {ok, Handler, Opts, Bindings};
match_trie([], #trie_node{handler = undefined}, _Bindings) ->
    {error, not_found};
match_trie(Segments, #trie_node{wildcard_child = {Name, WildNode}}, Bindings)
  when WildNode#trie_node.handler =/= undefined ->
    %% Wildcard captures rest of path
    WildPath = join_path(Segments),
    {Handler, Opts} = WildNode#trie_node.handler,
    {ok, Handler, Opts, Bindings#{Name => WildPath}};
match_trie([Segment | Rest], #trie_node{children = Children, param_child = PC}, Bindings) ->
    %% Try static match first
    case maps:find(Segment, Children) of
        {ok, ChildNode} ->
            case match_trie(Rest, ChildNode, Bindings) of
                {ok, _, _, _} = Result -> Result;
                {error, not_found} ->
                    %% Try parameter match
                    try_param_match(Segment, Rest, PC, Bindings)
            end;
        error ->
            %% Try parameter match
            try_param_match(Segment, Rest, PC, Bindings)
    end;
match_trie(_, _, _) ->
    {error, not_found}.

try_param_match(_Segment, _Rest, undefined, _Bindings) ->
    {error, not_found};
try_param_match(Segment, Rest, {Name, ChildNode}, Bindings) ->
    match_trie(Rest, ChildNode, Bindings#{Name => Segment}).

%%====================================================================
%% Internal - Helpers
%%====================================================================

split_path(<<>>) ->
    [];
split_path(<<"/">>) ->
    [];
split_path(Path) ->
    %% Remove leading slash and split
    Path1 = case Path of
        <<"/", Rest/binary>> -> Rest;
        _ -> Path
    end,
    %% Remove query string if present
    Path2 = case binary:split(Path1, <<"?">>) of
        [P, _] -> P;
        [P] -> P
    end,
    binary:split(Path2, <<"/">>, [global, trim_all]).

join_path([]) ->
    <<>>;
join_path(Segments) ->
    iolist_to_binary(lists:join(<<"/">>, Segments)).

ensure_binary(S) when is_list(S) -> list_to_binary(S);
ensure_binary(B) when is_binary(B) -> B.

normalize_method(get) -> get;
normalize_method(post) -> post;
normalize_method(put) -> put;
normalize_method(delete) -> delete;
normalize_method(patch) -> patch;
normalize_method(head) -> head;
normalize_method(options) -> options;
normalize_method(connect) -> connect;
normalize_method(trace) -> trace;
normalize_method('_') -> '_';
normalize_method(<<"GET">>) -> get;
normalize_method(<<"POST">>) -> post;
normalize_method(<<"PUT">>) -> put;
normalize_method(<<"DELETE">>) -> delete;
normalize_method(<<"PATCH">>) -> patch;
normalize_method(<<"HEAD">>) -> head;
normalize_method(<<"OPTIONS">>) -> options;
normalize_method(<<"CONNECT">>) -> connect;
normalize_method(<<"TRACE">>) -> trace;
normalize_method(M) when is_atom(M) -> M;
normalize_method(M) when is_binary(M) ->
    try binary_to_existing_atom(string:lowercase(M))
    catch _:_ -> binary_to_atom(string:lowercase(M))
    end.
