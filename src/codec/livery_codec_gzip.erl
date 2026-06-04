-module(livery_codec_gzip).
-moduledoc """
Built-in `gzip` content-coding over OTP `zlib`.

Emits RFC 1952 gzip framing (zlib WindowBits 31): one valid gzip member
with the header written once and the CRC/ISIZE trailer at finish, so the
streamed output decodes in any conformant client.
""".
-behaviour(livery_codec).

-export([name/0, compress/1, stream_init/0, stream_update/2, stream_finish/1, stream_close/1]).

-define(WINDOW_BITS, 31).

-doc "Content-Encoding token.".
-spec name() -> binary().
name() -> <<"gzip">>.

-doc "One-shot gzip of a whole body.".
-spec compress(iodata()) -> iodata().
compress(Data) -> zlib:gzip(Data).

-doc "Open a streaming gzip context.".
-spec stream_init() -> zlib:zstream().
stream_init() -> livery_codec_zlib:stream_init(?WINDOW_BITS).

-doc "Compress and flush one chunk.".
-spec stream_update(zlib:zstream(), iodata()) -> iodata().
stream_update(Z, Data) -> livery_codec_zlib:stream_update(Z, Data).

-doc "Trailing bytes finalizing the gzip member.".
-spec stream_finish(zlib:zstream()) -> iodata().
stream_finish(Z) -> livery_codec_zlib:stream_finish(Z).

-doc "Release the streaming context.".
-spec stream_close(zlib:zstream()) -> ok.
stream_close(Z) -> livery_codec_zlib:stream_close(Z).
