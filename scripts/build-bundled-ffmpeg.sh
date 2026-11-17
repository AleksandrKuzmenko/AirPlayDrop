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

# libass renders text subtitles for FFmpeg's `subtitles` filter, which burns
# them into the picture. It needs FreeType, FriBidi, and HarfBuzz; on macOS it
# finds fonts through Core Text, so fontconfig is not needed. All four are
# built as static libraries into one prefix. Checksums match Homebrew's pins.
freetype_version="2.15.0"
freetype_sha256="93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5"
freetype_url="https://downloads.sourceforge.net/project/freetype/freetype2/${freetype_version}/freetype-${freetype_version}.tar.xz"
fribidi_version="1.0.18"
fribidi_sha256="1de5e8073d035388b71d0b2d452b1da1f8caeea8a7702997b401fe1b6250727f"
fribidi_url="https://github.com/fribidi/fribidi/releases/download/v${fribidi_version}/fribidi-${fribidi_version}.tar.xz"
harfbuzz_version="15.0.0"
harfbuzz_sha256="968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df"
harfbuzz_url="https://github.com/harfbuzz/harfbuzz/releases/download/${harfbuzz_version}/harfbuzz-${harfbuzz_version}.tar.xz"
libass_version="0.17.5"
libass_sha256="2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc"
libass_url="https://github.com/libass/libass/releases/download/${libass_version}/libass-${libass_version}.tar.xz"
text_prefix="$work_root/text-deps-arm64"

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

# fetch_source NAME VERSION SHA256 URL: download, verify, and unpack a source
# archive into $work_root/NAME-VERSION.
fetch_source() {
  archive="$download_dir/$1-$2.tar.xz"
  if [ ! -f "$archive" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$4"
  fi
  verify_sha256 "$archive" "$3"
  if [ ! -f "$work_root/$1-$2/meson.build" ]; then
    rm -rf "$work_root/$1-$2"
    mkdir -p "$work_root/$1-$2"
    tar -xJf "$archive" --strip-components=1 -C "$work_root/$1-$2"
  fi
}
fetch_source freetype "$freetype_version" "$freetype_sha256" "$freetype_url"
fetch_source fribidi "$fribidi_version" "$fribidi_sha256" "$fribidi_url"
fetch_source harfbuzz "$harfbuzz_version" "$harfbuzz_sha256" "$harfbuzz_url"
fetch_source libass "$libass_version" "$libass_sha256" "$libass_url"

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

# meson_static NAME VERSION [OPTIONS...]: build a static library into
# $text_prefix. Subproject downloads are disabled so only pinned sources build.
arch_flags="-arch arm64 -isysroot $sdk_root -mmacosx-version-min=14.0"
meson_static() {
  name="$1-$2"
  shift 2
  rm -rf "$work_root/$name-build-arm64"
  CC="$(xcrun --sdk macosx --find clang)" CXX="$(xcrun --sdk macosx --find clang++)" \
  PKG_CONFIG_PATH="$text_prefix/lib/pkgconfig" \
  meson setup "$work_root/$name-build-arm64" "$work_root/$name" \
    --prefix="$text_prefix" \
    --libdir=lib \
    --buildtype=release \
    --default-library=static \
    --wrap-mode=nodownload \
    -Dc_args="$arch_flags" -Dc_link_args="$arch_flags" \
    -Dcpp_args="$arch_flags" -Dcpp_link_args="$arch_flags" \
    "$@"
  ninja -C "$work_root/$name-build-arm64"
  ninja -C "$work_root/$name-build-arm64" install
}
rm -rf "$text_prefix"
meson_static freetype "$freetype_version" \
  -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled -Dzlib=disabled -Dtests=disabled
meson_static fribidi "$fribidi_version" -Ddocs=false -Dbin=false -Dtests=false
meson_static harfbuzz "$harfbuzz_version" \
  -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled -Dpng=disabled -Dzlib=disabled \
  -Dicu=disabled -Dfreetype=disabled -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dsubset=disabled \
  -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled
meson_static libass "$libass_version" \
  -Dfontconfig=disabled -Dcoretext=enabled -Dlibunibreak=disabled -Drequire-system-font-provider=true \
  -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled
PKG_CONFIG_PATH="$dav1d_prefix/lib/pkgconfig:$text_prefix/lib/pkgconfig"
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
  --extra-libs="-liconv -lc++" \
  --disable-debug \
  --disable-doc \
  --disable-ffplay \
  --disable-network \
  --disable-autodetect \
  --disable-gpl \
  --disable-nonfree \
  --disable-encoders \
  --enable-encoder=aac,eac3,h264_videotoolbox,hevc_videotoolbox,movtext \
  --disable-muxers \
  --enable-muxer=mp4,mov \
  --disable-filters \
  --enable-filter=acompressor,adelay,aformat,alimiter,anull,aresample,asetpts,atrim,bwdif,colorchannelmixer,format,hwdownload,hwupload,null,overlay,scale,scale_vt,setparams,setpts,subtitles \
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
  --enable-libass \
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
"$install_dir/bin/ffmpeg" -hide_banner -encoders 2>&1 | grep -q ' eac3 '
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'acompressor'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'alimiter'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'adelay'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'atrim'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'asetpts'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'setparams'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'bwdif'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q ' overlay '
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'colorchannelmixer'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q ' setpts '
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'scale_vt'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'hwupload'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q 'hwdownload'
"$install_dir/bin/ffmpeg" -hide_banner -bsfs 2>&1 | grep -q 'filter_units'
"$install_dir/bin/ffmpeg" -hide_banner -bsfs 2>&1 | grep -q 'setts'
"$install_dir/bin/ffmpeg" -hide_banner -muxers 2>&1 | grep -q 'mp4'
"$install_dir/bin/ffmpeg" -hide_banner -decoders 2>&1 | grep -q 'libdav1d'
"$install_dir/bin/ffmpeg" -hide_banner -filters 2>&1 | grep -q ' subtitles '

mkdir -p "$install_dir/licenses"
cp "$source_dir/COPYING.LGPLv2.1" "$install_dir/licenses/FFmpeg-LGPL-2.1.txt"
cp "$source_dir/LICENSE.md" "$install_dir/licenses/FFmpeg-LICENSE.md"
cp "$dav1d_source_dir/COPYING" "$install_dir/licenses/dav1d-COPYING.txt"
cp "$work_root/libass-$libass_version/COPYING" "$install_dir/licenses/libass-COPYING.txt"
cp "$work_root/harfbuzz-$harfbuzz_version/COPYING" "$install_dir/licenses/HarfBuzz-COPYING.txt"
cp "$work_root/harfbuzz-$harfbuzz_version/src/ms-use/COPYING" "$install_dir/licenses/HarfBuzz-ms-use-COPYING.txt"
cp "$work_root/fribidi-$fribidi_version/COPYING" "$install_dir/licenses/FriBidi-COPYING.txt"
cp "$work_root/freetype-$freetype_version/LICENSE.TXT" "$install_dir/licenses/FreeType-LICENSE.txt"
cp "$work_root/freetype-$freetype_version/docs/FTL.TXT" "$install_dir/licenses/FreeType-FTL.txt"
# FriBidi is LGPL and statically linked, so its source ships with FFmpeg's.
cp "$download_dir/fribidi-$fribidi_version.tar.xz" "$install_dir/licenses/"
printf '%s  %s\n' "$fribidi_sha256" "fribidi-$fribidi_version.tar.xz" > "$install_dir/licenses/fribidi-$fribidi_version.tar.xz.sha256"
cp "$source_archive" "$install_dir/licenses/ffmpeg-${ffmpeg_version}.tar.xz"
printf '%s  %s\n' "$ffmpeg_sha256" "ffmpeg-${ffmpeg_version}.tar.xz" > "$install_dir/licenses/ffmpeg-${ffmpeg_version}.tar.xz.sha256"

echo "Built LGPL FFmpeg $ffmpeg_version for arm64 at $install_dir"
