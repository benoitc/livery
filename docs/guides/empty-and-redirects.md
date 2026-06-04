# How to send an empty or redirect response

## Empty response

```erlang
livery_resp:empty(204).   %% No Content
livery_resp:empty(304).   %% Not Modified
```

`empty/1` sends the headers with `end_stream` set, and not a single
body byte goes out on the wire. Handy whenever the status says
everything: a `204` after a successful delete, a `304` for a cache
hit.

## Redirect

```erlang
livery_resp:redirect(302, <<"/login">>).
livery_resp:redirect(308, <<"https://example.com/api/v2/items">>).
```

The builder fills in the `Location` header and leaves the body
empty. Need extra headers? Pass them as a third argument:

```erlang
livery_resp:redirect(303, <<"/items/42">>,
    [{<<"cache-control">>, <<"no-store">>}]).
```

## Common patterns

```erlang
%% After a POST that created a resource
livery_resp:redirect(303, [<<"/items/">>, Id]).

%% Force HTTPS upgrade
livery_resp:redirect(301, [<<"https://">>, livery_req:authority(Req),
                           livery_req:path(Req)]).
```

## See also

- Reference: `livery_resp`
