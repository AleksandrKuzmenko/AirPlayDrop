#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
version="${AIRPLAYDROP_VERSION:-0.1.0}"
build_root="${AIRPLAYDROP_BUILD_ROOT:-$repo_root/.build}"
ffmpeg_root="$build_root/ffmpeg-arm64"
derived_data="$build_root/DerivedData-Release"
dist_dir="${AIRPLAYDROP_DIST_DIR:-$repo_root/dist}"
identity="${DEVELOPER_ID_APPLICATION:-}"
notary_profile="${NOTARY_PROFILE:-}"

if [ ! -x "$ffmpeg_root/bin/ffmpeg" ] || [ ! -x "$ffmpeg_root/bin/ffprobe" ]; then
  "$repo_root/scripts/build-bundled-ffmpeg.sh" "$ffmpeg_root"
fi

mkdir -p "$dist_dir"
xcodebuild \
  -project "$repo_root/AirPlayDrop/AirPlayDrop.xcodeproj" \
  -scheme AirPlayDrop \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO build

app="$derived_data/Build/Products/Release/AirPlayDrop.app"
resources="$app/Contents/Resources"
mkdir -p "$resources/bin" "$resources/Licenses/FFmpeg" "$resources/Licenses/dav1d"
cp "$ffmpeg_root/bin/ffmpeg" "$ffmpeg_root/bin/ffprobe" "$resources/bin/"
cp "$ffmpeg_root/licenses/FFmpeg-LGPL-2.1.txt" "$ffmpeg_root/licenses/FFmpeg-LICENSE.md" \
  "$resources/Licenses/FFmpeg/"
cp "$ffmpeg_root/licenses/dav1d-COPYING.txt" "$resources/Licenses/dav1d/COPYING.txt"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$resources/"

if [ -z "$identity" ]; then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' | head -n 1)
fi

if [ -z "$identity" ]; then
  if [ "${ALLOW_ADHOC:-0}" != "1" ]; then
    echo "No Developer ID Application identity is installed." >&2
    echo "Install one, then set DEVELOPER_ID_APPLICATION and NOTARY_PROFILE." >&2
    exit 2
  fi
  identity="-"
fi

sign_args="--force --options runtime --timestamp=none --sign"
if [ "$identity" != "-" ]; then sign_args="--force --options runtime --timestamp --sign"; fi
# shellcheck disable=SC2086
codesign $sign_args "$identity" "$resources/bin/ffmpeg"
# shellcheck disable=SC2086
codesign $sign_args "$identity" "$resources/bin/ffprobe"
# shellcheck disable=SC2086
codesign $sign_args "$identity" --entitlements "$repo_root/AirPlayDrop/AirPlayDrop/AirPlayDrop.entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

if [ "$identity" != "-" ]; then
  if [ -z "$notary_profile" ]; then
    echo "NOTARY_PROFILE must name credentials stored with xcrun notarytool store-credentials." >&2
    exit 2
  fi
  app_zip="$build_root/AirPlayDrop-${version}-arm64-notary.zip"
  ditto -c -k --keepParent "$app" "$app_zip"
  xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi

stage=$(mktemp -d "$build_root/dmg-stage.XXXXXX")
ditto "$app" "$stage/AirPlayDrop.app"
if [ ! -e "$stage/Applications" ]; then ln -s /Applications "$stage/Applications"; fi

suffix=""
if [ "$identity" = "-" ]; then suffix="-adhoc"; fi
dmg="$dist_dir/AirPlayDrop-${version}-arm64${suffix}.dmg"
hdiutil create -volname AirPlayDrop -srcfolder "$stage" -ov -format UDZO "$dmg"
rm -rf "$stage"

if [ "$identity" != "-" ]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
  xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi

cp "$ffmpeg_root/licenses/ffmpeg-9.0.2.tar.xz" "$ffmpeg_root/licenses/ffmpeg-9.0.2.tar.xz.sha256" "$dist_dir/"
dmg_name=$(basename "$dmg")
(cd "$dist_dir" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256")
echo "Created $dmg"
