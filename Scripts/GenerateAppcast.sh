#!/bin/bash
set -euo pipefail

app="${1:?Pass the signed app bundle}"
zip="${2:?Pass the signed macOS ZIP}"
generator="${3:?Pass the Sparkle generate_appcast tool}"
download_prefix="${4:?Pass the URL prefix for the release assets}"
: "${SPARKLE_EDDSA_PRIVATE_KEY:?Add the Sparkle signing key to macos-release}"

directory=$(dirname "$zip")
feed="$directory/appcast.xml"
signer="$(dirname "$generator")/sign_update"
verify_feed() {
    printf '%s\n' "$SPARKLE_EDDSA_PRIVATE_KEY" | "$signer" --verify --ed-key-file - "$feed"
}

build=$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")
if [[ ! "$build" =~ ^[1-9][0-9]*$ ]]; then
    echo 'Sparkle requires a positive integer CFBundleVersion for this release.' >&2
    exit 1
fi
if [[ -f "$feed" ]]; then
    verify_feed
    newer_builds=$(xmllint --xpath "count(/rss/channel/item/*[local-name()='version'][number(.) >= $build])" "$feed")
    if [[ "$newer_builds" != 0 ]]; then
        echo 'Increase the build number above all builds in the published appcast.' >&2
        exit 1
    fi
fi

printf '%s\n' "$SPARKLE_EDDSA_PRIVATE_KEY" | "$generator" --ed-key-file - \
    --versions "$build" --maximum-deltas 0 --download-url-prefix "$download_prefix" "$directory"
verify_feed

url="$download_prefix${zip##*/}"
length=$(stat -f '%z' "$zip")
enclosure="/rss/channel/item[*[local-name()='version']='$build']/enclosure"
if [[ $(xmllint --xpath "count($enclosure[@url='$url' and @length='$length' and @*[local-name()='edSignature']])" "$feed") != 1 ]]; then
    echo 'The appcast must contain a signed enclosure for the released ZIP.' >&2
    exit 1
fi
