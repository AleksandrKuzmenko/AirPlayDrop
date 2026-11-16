#!/bin/sh
set -eu

ffmpeg_version="9.0.2"
ffmpeg_sha256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
source_url="https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz"
repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work_root="${AIRPLAYDROP_BUILD_ROOT:-$repo_root/.build}"
download_dir="$work_root/downloads"
source_archive="$download_dir/ffmpeg-${ffmpeg_version}.tar.xz"
source_dir="$work_root/ffmpeg-${ffmpeg_version}"
install_dir="${1:-$work_root/ffmpeg-arm64}"

case "$(uname -m)" in
  arm64) ;;
  *) echo "Bundled FFmpeg must be built natively on Apple Silicon." >&2; exit 1 ;;
esac

mkdir -p "$download_dir"
if [ ! -f "$source_archive" ]; then
  curl --fail --location --proto '=https' --tlsv1.2 --output "$source_archive" "$source_url"
fi
actual_sha=$(shasum -a 256 "$source_archive" | awk '{print $1}')
if [ "$actual_sha" != "$ffmpeg_sha256" ]; then
  echo "FFmpeg source checksum mismatch: $actual_sha" >&2
  exit 1
fi

if [ ! -x "$source_dir/configure" ]; then
  mkdir -p "$source_dir"
  tar -xJf "$source_archive" --strip-components=1 -C "$source_dir"
fi

build_dir="$work_root/ffmpeg-${ffmpeg_version}-build-arm64"
mkdir -p "$build_dir" "$install_dir"
cd "$build_dir"
if [ -f Makefile ]; then
  make distclean
fi
sdk_root=$(xcrun --sdk macosx --show-sdk-path)

"$source_dir/configure" \
  --prefix=/ \
  --arch=arm64 \
  --target-os=darwin \
  --cc="$(xcrun --sdk macosx --find clang)" \
  --host-cc="$(xcrun --sdk macosx --find clang)" \
  --host-cflags="-isysroot $sdk_root" \
  --host-ldflags="-isysroot $sdk_root" \
  --sysroot="$sdk_root" \
  --extra-cflags="-arch arm64 -mmacosx-version-min=14.0" \
  --extra-ldflags="-arch arm64 -mmacosx-version-min=14.0" \
  --extra-libs="-liconv" \
  --disable-debug \
  --disable-doc \
  --disable-ffplay \
  --disable-network \
  --disable-autodetect \
  --disable-gpl \
  --disable-nonfree \
  --disable-encoders \
  --enable-encoder=aac,h264_videotoolbox,hevc_videotoolbox,movtext \
  --disable-muxers \
  --enable-muxer=mp4,mov \
  --disable-filters \
  --enable-filter=acompressor,adelay,aformat,alimiter,anull,aresample,asetpts,atrim,format,null,scale \
  --disable-protocols \
  --enable-protocol=file,pipe \
  --disable-indevs \
  --disable-outdevs \
  --enable-zlib \
  --enable-bzlib \
  --enable-iconv \
  --enable-audiotoolbox \
  --enable-videotoolbox \
  --enable-pthreads

make -j"$(sysctl -n hw.logicalcpu)"
make DESTDIR="$install_dir" install
strip -x "$install_dir/bin/ffmpeg" "$install_dir/bin/ffprobe"

for executable in ffmpeg ffprobe; do
  test "$(lipo -archs "$install_dir/bin/$executable")" = "arm64"
  if otool -L "$install_dir/bin/$executable" | grep -q '/opt/homebrew\|/usr/local'; then
    echo "$executable unexpectedly links to a package-manager library." >&2
    exit 1
  fi
done

"$install_dir/bin/ffmpeg" -hide_banner -encoders 2>&1 | grep -q 'h264_videotoolbox'
"$install_dir/bin/ffmpeg" -hide_banner -encoders 2>&1 | grep -q 'hevc_videotoolbox'
"$install_dir/bin/ffmpeg" -hide_banner -encoders 2>&1 | grep -q 'mov_text'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'acompressor'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'alimiter'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'adelay'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'atrim'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'asetpts'
"$install_dir/bin/ffmpeg" -hide_banner -bsfs 2>&1 | grep -q 'filter_units'
"$install_dir/bin/ffmpeg" -hide_banner -bsfs 2>&1 | grep -q 'setts'
"$install_dir/bin/ffmpeg" -hide_banner -muxers 2>&1 | grep -q 'mp4'

mkdir -p "$install_dir/licenses"
cp "$source_dir/COPYING.LGPLv2.1" "$install_dir/licenses/FFmpeg-LGPL-2.1.txt"
cp "$source_dir/LICENSE.md" "$install_dir/licenses/FFmpeg-LICENSE.md"
cp "$source_archive" "$install_dir/licenses/ffmpeg-${ffmpeg_version}.tar.xz"
printf '%s  %s\n' "$ffmpeg_sha256" "ffmpeg-${ffmpeg_version}.tar.xz" > "$install_dir/licenses/ffmpeg-${ffmpeg_version}.tar.xz.sha256"

echo "Built LGPL FFmpeg $ffmpeg_version for arm64 at $install_dir"
