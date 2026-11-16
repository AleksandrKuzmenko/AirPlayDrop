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

# dav1d provides software AV1 decoding. FFmpeg's built-in AV1 decoder only
# works with a hardware accelerator, and Apple silicon before M3 has none.
dav1d_version="1.5.4"
dav1d_sha256="686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"
dav1d_url="https://downloads.videolan.org/pub/videolan/dav1d/${dav1d_version}/dav1d-${dav1d_version}.tar.xz"
dav1d_archive="$download_dir/dav1d-${dav1d_version}.tar.xz"
dav1d_source_dir="$work_root/dav1d-${dav1d_version}"
dav1d_build_dir="$work_root/dav1d-${dav1d_version}-build-arm64"
dav1d_prefix="$work_root/dav1d-${dav1d_version}-arm64"

case "$(uname -m)" in
  arm64) ;;
  *) echo "Bundled FFmpeg must be built natively on Apple Silicon." >&2; exit 1 ;;
esac

for tool in meson ninja pkg-config; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required to build dav1d. Install it with: brew install meson ninja pkgconf" >&2
    exit 1
  fi
done

verify_sha256() {
  actual_sha=$(shasum -a 256 "$1" | awk '{print $1}')
  if [ "$actual_sha" != "$2" ]; then
    echo "Source checksum mismatch for $1: $actual_sha" >&2
    exit 1
  fi
}

mkdir -p "$download_dir"
if [ ! -f "$source_archive" ]; then
  curl --fail --location --proto '=https' --tlsv1.2 --output "$source_archive" "$source_url"
fi
verify_sha256 "$source_archive" "$ffmpeg_sha256"
if [ ! -f "$dav1d_archive" ]; then
  curl --fail --location --proto '=https' --tlsv1.2 --output "$dav1d_archive" "$dav1d_url"
fi
verify_sha256 "$dav1d_archive" "$dav1d_sha256"

if [ ! -x "$source_dir/configure" ]; then
  mkdir -p "$source_dir"
  tar -xJf "$source_archive" --strip-components=1 -C "$source_dir"
fi
if [ ! -f "$dav1d_source_dir/meson.build" ]; then
  mkdir -p "$dav1d_source_dir"
  tar -xJf "$dav1d_archive" --strip-components=1 -C "$dav1d_source_dir"
fi

sdk_root=$(xcrun --sdk macosx --show-sdk-path)

rm -rf "$dav1d_build_dir" "$dav1d_prefix"
CC="$(xcrun --sdk macosx --find clang)" meson setup "$dav1d_build_dir" "$dav1d_source_dir" \
  --prefix="$dav1d_prefix" \
  --libdir=lib \
  --buildtype=release \
  --default-library=static \
  -Denable_tools=false \
  -Denable_tests=false \
  -Denable_examples=false \
  -Denable_docs=false \
  -Dc_args="-arch arm64 -isysroot $sdk_root -mmacosx-version-min=14.0" \
  -Dc_link_args="-arch arm64 -isysroot $sdk_root -mmacosx-version-min=14.0"
ninja -C "$dav1d_build_dir"
ninja -C "$dav1d_build_dir" install
PKG_CONFIG_PATH="$dav1d_prefix/lib/pkgconfig"
export PKG_CONFIG_PATH

build_dir="$work_root/ffmpeg-${ffmpeg_version}-build-arm64"
# Start from an empty directory: `make distclean` leaves dependency files in
# nested source folders, which break the build after an Xcode SDK update.
rm -rf "$build_dir"
mkdir -p "$build_dir" "$install_dir"
cd "$build_dir"

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
  --enable-filter=acompressor,adelay,aformat,alimiter,anull,aresample,asetpts,atrim,format,null,scale,setparams \
  --disable-protocols \
  --enable-protocol=file,pipe \
  --disable-indevs \
  --disable-outdevs \
  --enable-zlib \
  --enable-bzlib \
  --enable-iconv \
  --enable-audiotoolbox \
  --enable-videotoolbox \
  --enable-pthreads \
  --enable-libdav1d \
  --pkg-config-flags=--static

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
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'setparams'
"$install_dir/bin/ffmpeg" -hide_banner -bsfs 2>&1 | grep -q 'filter_units'
"$install_dir/bin/ffmpeg" -hide_banner -bsfs 2>&1 | grep -q 'setts'
"$install_dir/bin/ffmpeg" -hide_banner -muxers 2>&1 | grep -q 'mp4'
"$install_dir/bin/ffmpeg" -hide_banner -decoders 2>&1 | grep -q 'libdav1d'

mkdir -p "$install_dir/licenses"
cp "$source_dir/COPYING.LGPLv2.1" "$install_dir/licenses/FFmpeg-LGPL-2.1.txt"
cp "$source_dir/LICENSE.md" "$install_dir/licenses/FFmpeg-LICENSE.md"
cp "$dav1d_source_dir/COPYING" "$install_dir/licenses/dav1d-COPYING.txt"
cp "$source_archive" "$install_dir/licenses/ffmpeg-${ffmpeg_version}.tar.xz"
printf '%s  %s\n' "$ffmpeg_sha256" "ffmpeg-${ffmpeg_version}.tar.xz" > "$install_dir/licenses/ffmpeg-${ffmpeg_version}.tar.xz.sha256"

echo "Built LGPL FFmpeg $ffmpeg_version for arm64 at $install_dir"
