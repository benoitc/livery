-module(livery_codec_deflate).
-moduledoc """
Built-in `deflate` content-coding over OTP `zlib`.

Emits zlib-wrapped DEFLATE (RFC 1950, WindowBits 15), which is the
spec-correct `deflate` content-coding (NOT raw DEFLATE). Decodes with
`zlib:uncompress/1` and any conformant client.
""".
-behaviour(livery_codec).

-export([name/0, compress/1, stream_init/0, stream_update/2, stream_finish/1, stream_close/1]).

-define(WINDOW_BITS, 15).

-doc "Content-Encoding token.".
-spec name() -> binary().
name() -> <<"deflate">>.

-doc "One-shot zlib-wrapped DEFLATE of a whole body.".
-spec compress(iodata()) -> iodata().
compress(Data) -> zlib:compress(Data).

-doc "Open a streaming deflate context.".
-spec stream_init() -> zlib:zstream().
stream_init() -> livery_codec_zlib:stream_init(?WINDOW_BITS).

-doc "Compress and flush one chunk.".
-spec stream_update(zlib:zstream(), iodata()) -> iodata().
stream_update(Z, Data) -> livery_codec_zlib:stream_update(Z, Data).

-doc "Trailing bytes finalizing the deflate stream.".
-spec stream_finish(zlib:zstream()) -> iodata().
stream_finish(Z) -> livery_codec_zlib:stream_finish(Z).

-doc "Release the streaming context.".
-spec stream_close(zlib:zstream()) -> ok.
stream_close(Z) -> livery_codec_zlib:stream_close(Z).
