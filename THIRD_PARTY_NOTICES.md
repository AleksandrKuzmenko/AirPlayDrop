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
