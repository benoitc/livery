# Tutorial: Your first service

In this tutorial you build a small set of REST handlers, run them from
end to end through `livery_test_adapter`, and see what a Livery handler
looks like. No socket is involved, so this is the right starting
point if you have never written a Livery handler before. About 10
minutes.

## What you will build

Three handlers backed by an in-memory list:

| Route | Handler | Purpose |
|---|---|---|
| `GET /items` | `items:index/1` | list items as JSON |
| `GET /items/:id` | `items:show/1` | one item, 404 if missing |
| `POST /items` | `items:create/1` | accept a JSON body, return 201 |

## 1. Write the handlers

`src/items.erl`:

```erlang
-module(items).
-export([index/1, show/1, create/1]).

index(_Req) ->
    Body = json:encode(store()),
    livery_resp:json(200, Body).

show(Req) ->
    Id = livery_req:binding(<<"id">>, Req),
    case lists:keyfind(Id, 1, store()) of
        {Id, Item} -> livery_resp:json(200, json:encode(Item));
        false      -> livery_resp:text(404, <<"not found">>)
    end.

create(Req) ->
    case livery_ext:json(Req) of
        {ok, #{<<"name">> := _} = Item} ->
            livery_resp:json(201, json:encode(Item));
        {error, _} ->
            livery_resp:text(400, <<"bad json">>)
    end.

store() ->
    [{<<"1">>, #{name => <<"hammer">>}},
     {<<"2">>, #{name => <<"nail">>}}].
```

## 2. Drive them through the test adapter

`test/items_tests.erl`:

```erlang
-module(items_tests).
-include_lib("eunit/include/eunit.hrl").

index_returns_list_test() ->
    Cap = livery_test_adapter:run(
        [], fun items:index/1, #{method => <<"GET">>}),
    ?assertEqual(200, livery_test_adapter:status(Cap)),
    ?assertEqual(<<"application/json">>,
                 livery_test_adapter:header(<<"content-type">>, Cap)).

show_404_when_missing_test() ->
    Cap = livery_test_adapter:run(
        [], fun items:show/1,
        #{method => <<"GET">>,
          bindings => #{<<"id">> => <<"99">>}}),
    ?assertEqual(404, livery_test_adapter:status(Cap)).

create_accepts_valid_json_test() ->
    Cap = livery_test_adapter:run(
        [], fun items:create/1,
        #{method => <<"POST">>,
          body => {buffered, <<"{\"name\":\"saw\"}">>}}),
    ?assertEqual(201, livery_test_adapter:status(Cap)).

create_rejects_bad_json_test() ->
    Cap = livery_test_adapter:run(
        [], fun items:create/1,
        #{method => <<"POST">>,
          body => {buffered, <<"not json">>}}),
    ?assertEqual(400, livery_test_adapter:status(Cap)).
```

Run `rebar3 eunit`. All four tests pass.

## 3. What the test adapter gave you

`livery_test_adapter:run/3` did three things:

1. Built a `#livery_req{}` value from the spec map.
2. Ran `livery:dispatch/3` (middleware stack plus handler).
3. Turned the response into adapter calls with `livery:emit/3`,
   recording the status, headers, body chunks, and trailers.

The same pipeline runs unchanged under the H1, H2 and H3 adapters.
The only thing the test adapter replaces is the network.

## 4. Anatomy of a handler

A handler is a function `fun(livery_req:req()) -> livery_resp:resp()`.

- Reads inputs via `livery_req` accessors or `livery_ext` extractors.
- Returns an immutable `#livery_resp{}` value built by
  `livery_resp:text/2`, `:json/2`, `:empty/1`, etc.
- Never touches a socket directly.

There is no `init/2`, no `cowboy_req:reply`, no tuples to return. One
request in, one response out.

## Next steps

- [Compose a middleware stack](middleware-stack.md)
- [Stream a response](streaming-responses.md)
- [Test your handlers](testing-handlers.md)
