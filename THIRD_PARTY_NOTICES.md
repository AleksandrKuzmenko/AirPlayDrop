# Third-party software

## FFmpeg 9.0.2

AirPlayDrop includes the separate `ffmpeg` and `ffprobe` command-line programs
from the FFmpeg project. They are built for Apple Silicon from unmodified FFmpeg
9.0.2 source and are licensed under the GNU Lesser General Public License,
version 2.1 or later. AirPlayDrop communicates with these programs through
structured process arguments and does not link to FFmpeg libraries.

Source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz

SHA-256: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`

The build deliberately disables GPL and nonfree components, external library
autodetection, networking, documentation, and FFplay. It retains broad built-in
decoding and demuxing for user media while limiting encoders, muxers, filters,
protocols, and devices to AirPlayDrop's preparation paths. It enables Apple
AudioToolbox and VideoToolbox plus system zlib, bzip2, and iconv support. The
complete corresponding FFmpeg source archive and checksum are distributed next
to the AirPlayDrop disk image. The FFmpeg license texts are included inside the
application under `Contents/Resources/Licenses/FFmpeg`.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
AirPlayDrop is not affiliated with or endorsed by the FFmpeg project.

## dav1d 1.5.4

The bundled `ffmpeg` and `ffprobe` statically include dav1d, the VideoLAN AV1
decoder, so AV1 video can be decoded on every supported Mac. dav1d is licensed
under the BSD 2-Clause License, copyright © 2018-2025 VideoLAN and dav1d
authors. Its license text is included inside the application under
`Contents/Resources/Licenses/dav1d`.

Source: https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz

SHA-256: `686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5`

## Subtitle rendering: libass 0.17.5, HarfBuzz 15.0.0, FriBidi 1.0.18, FreeType 2.15.0

The bundled `ffmpeg` statically includes libass and the libraries it needs to
render text subtitles into video. libass finds fonts through macOS Core Text,
so fontconfig is not included. License texts are included inside the
application under `Contents/Resources/Licenses`.

- **libass 0.17.5**, ISC License, copyright © 2006-2016 libass contributors.
  Source: https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz
  SHA-256: `2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc`
- **HarfBuzz 15.0.0**, "Old MIT" license, copyright © HarfBuzz contributors
  (see `Licenses/HarfBuzz/COPYING.txt`). It includes Microsoft Universal Shaping
  Engine data under the MIT License, copyright © Microsoft Corporation.
  Source: https://github.com/harfbuzz/harfbuzz/releases/download/15.0.0/harfbuzz-15.0.0.tar.xz
  SHA-256: `968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df`
- **FriBidi 1.0.18**, GNU Lesser General Public License, version 2.1 or later.
  Because it is statically linked, its complete source archive and checksum are
  distributed next to the AirPlayDrop disk image, with FFmpeg's.
  Source: https://github.com/fribidi/fribidi/releases/download/v1.0.18/fribidi-1.0.18.tar.xz
  SHA-256: `1de5e8073d035388b71d0b2d452b1da1f8caeea8a7702997b401fe1b6250727f`
- **FreeType 2.15.0**, used under the FreeType License (FTL).
  Portions of this software are copyright © 2026 The FreeType Project
  (https://freetype.org). All rights reserved.
  Source: https://downloads.sourceforge.net/project/freetype/freetype2/2.15.0/freetype-2.15.0.tar.xz
  SHA-256: `93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5`
