#!/bin/bash
set -euo pipefail

derived_data_path="${1:?Pass a DerivedData path}"

xcodebuild \
    -project UsageNotch.xcodeproj \
    -scheme UsageNotch \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS='arm64 x86_64' \
    build
