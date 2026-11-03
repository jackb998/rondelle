# LAME 4.0 — libmp3lame (encoder only)

- Source: https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz (released 11 July 2026)
- SHA-256: `3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb` (same as Homebrew's)
- Differences from LAME 3.100 (SHA-256 `ddfe36ca…b1da1e`, the one Linux distributions ship), read in full:
  bug fixes, UTF-8 ID3v2.4 tags, decoder moved to mpg123. No network, processes or files.
- Copied: `libmp3lame/*.c|*.h` and `include/lame.h`. Left out: `mpglib_interface.c` (decoder), x86 assembly,
  `frontend` (command-line program), `mpglib`. `config.h` is written by hand (there is no `configure` step).
- Licence: LGPL 2 (see `COPYING`, `LICENSE`). The code is unmodified.
  Personal use carries no obligations; when the app is distributed, this code must be offered and the app
  must be relinkable against another version of LAME.
- Use in Rondelle: encoding only, of PCM samples already decoded by AVFoundation, without ID3 tags.
