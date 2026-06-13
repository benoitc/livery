# How to send an empty or redirect response

Some responses carry no body: a `204 No Content` after a successful
delete, a `304 Not Modified`, or a redirect that points the client
elsewhere. `livery_resp` gives you small builders for both, so you
return the right status without assembling headers by hand.

## Send an empty response

```erlang
livery_resp:empty(204).   %% No Content
livery_resp:empty(304).   %% Not Modified
```

`empty/1` sends headers with `end_stream` set; no body bytes are
emitted on the wire.

## Redirect

```erlang
livery_resp:redirect(302, <<"/login">>).
livery_resp:redirect(308, <<"https://example.com/api/v2/items">>).
```

The builder sets the `Location` header and an empty body. Pass
additional headers as a third argument:

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
