-module(livery_codec).
-moduledoc """
Content-coding codec behaviour and registry.

A codec turns response bytes into a single content-coding (the token
sent in `Content-Encoding`, e.g. `gzip`). `livery_compress` negotiates
the client's `Accept-Encoding` against the registered codecs and applies
the chosen one to `{full, _}` and `{chunked, _}` bodies.

The built-in codecs `livery_codec_gzip` and `livery_codec_deflate` are
always available (over OTP `zlib`, no dependency). A separate app (a
future `livery_brotli` or `livery_zstd`) adds its coding by calling
`register/1` at its own application start; it then participates in
negotiation without any change to livery core.

## Callbacks

- `name/0` — the `Content-Encoding` token (lowercase binary).
- `compress/1` — one-shot compression of a whole body (`{full, _}`).
- `stream_init/0` — open a streaming context.
- `stream_update/2` — feed a chunk and FLUSH, returning the bytes
  emittable now (so each producer chunk reaches the client promptly).
- `stream_finish/1` — return the trailing bytes that finalize the
  stream. Does not release the context.
- `stream_close/1` — release the context; always called, including on
  the error path.
""".

-compile({no_auto_import, [registered/0]}).

-export([register/1, registered/0, lookup/1]).

-export_type([codec/0]).

-type codec() :: module().

-callback name() -> binary().
-callback compress(iodata()) -> iodata().
-callback stream_init() -> term().
-callback stream_update(term(), iodata()) -> iodata().
-callback stream_finish(term()) -> iodata().
-callback stream_close(term()) -> ok.

-define(EXTRAS_KEY, {?MODULE, extras}).
-define(BUILTINS, [livery_codec_gzip, livery_codec_deflate]).

-doc """
Register an extra codec module.

Idempotent; built-in codecs are ignored (always present). Intended to be
called once at the registering app's start, not per request.
""".
-spec register(codec()) -> ok.
register(Module) when is_atom(Module) ->
    Extras = persistent_term:get(?EXTRAS_KEY, []),
    case lists:member(Module, Extras) orelse lists:member(Module, ?BUILTINS) of
        true ->
            ok;
        false ->
            persistent_term:put(?EXTRAS_KEY, Extras ++ [Module]),
            ok
    end.

-doc """
All registered codecs in server-preference order.

Always begins with the built-ins (`gzip`, then `deflate`), followed by
any extras in registration order. The built-ins can never be dropped by
registration.
""".
-spec registered() -> [codec()].
registered() ->
    ?BUILTINS ++ persistent_term:get(?EXTRAS_KEY, []).

-doc "Find a registered codec by `Content-Encoding` token (case-insensitive).".
-spec lookup(binary()) -> {ok, codec()} | error.
lookup(Name) when is_binary(Name) ->
    find(normalize(Name), registered()).

-spec find(binary(), [codec()]) -> {ok, codec()} | error.
find(_Lower, []) ->
    error;
find(Lower, [Module | Rest]) ->
    case normalize(Module:name()) =:= Lower of
        true -> {ok, Module};
        false -> find(Lower, Rest)
    end.

-spec normalize(binary()) -> binary().
normalize(Bin) ->
    iolist_to_binary(string:lowercase(Bin)).
