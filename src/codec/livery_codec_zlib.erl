-module(livery_codec_zlib).
-moduledoc """
Shared OTP `zlib` streaming backend for the gzip and deflate codecs.

The two built-in codecs differ only in the zlib `WindowBits` value
(31 for gzip framing, 15 for zlib-wrapped DEFLATE), so the streaming
machinery lives here once. `stream_update/2` uses a sync flush so each
producer chunk is emittable immediately.
""".

-export([stream_init/1, stream_update/2, stream_finish/1, stream_close/1]).

-doc "Open a deflate stream with the given zlib WindowBits.".
-spec stream_init(integer()) -> zlib:zstream().
stream_init(WindowBits) ->
    Z = zlib:open(),
    ok = zlib:deflateInit(Z, default, deflated, WindowBits, 8, default),
    Z.

-doc "Compress a chunk and flush, returning the bytes emittable now.".
-spec stream_update(zlib:zstream(), iodata()) -> iodata().
stream_update(Z, Data) ->
    zlib:deflate(Z, Data, sync).

-doc "Return the trailing bytes that finalize the stream.".
-spec stream_finish(zlib:zstream()) -> iodata().
stream_finish(Z) ->
    zlib:deflate(Z, <<>>, finish).

-doc "Release the stream. Frees the underlying zlib resource.".
-spec stream_close(zlib:zstream()) -> ok.
stream_close(Z) ->
    zlib:close(Z),
    ok.
