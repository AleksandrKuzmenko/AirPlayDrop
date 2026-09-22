#!/bin/sh
set -eu

project="AirPlayDrop/AirPlayDrop.xcodeproj"
scheme="AirPlayDrop"
destination="platform=macOS,arch=$(uname -m)"

xcodebuild -project "$project" -scheme "$scheme" -configuration Debug -sdk macosx \
  -destination "$destination" build CODE_SIGNING_ALLOWED=NO
xcodebuild -project "$project" -scheme "$scheme" -destination "$destination" \
  test CODE_SIGNING_ALLOWED=NO
git diff --check
