# libwebp 1.6.0 (encoder only)

- Source: https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz
- SHA-256: `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564` (same as Homebrew's)
- The `.c`/`.h` files are identical to the official git tag `v1.6.0` on chromium.googlesource.com/webm/libwebp.
- Copied: `src/enc`, `src/dsp`, `src/utils`, `src/webp`, `sharpyuv` and only the `src/dec/*.h` headers (needed by `dsp`). Left out: decoder code, demux, mux, examples, tools.
- Licence: BSD (see `COPYING`, `PATENTS`). The code is unmodified.
- Use in Rondelle: only `WebPEncodeRGBA`, on pixels already decoded by ImageIO (no external file reaches it).
- To update: download the new version, check the SHA-256 and the git tag, replace the same folders.
