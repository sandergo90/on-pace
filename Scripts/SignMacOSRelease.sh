#!/bin/bash
set -euo pipefail
umask 077

app="${1:?Pass the unsigned app bundle}"
zip="${2:?Pass the output ZIP path}"
version="${3:?Pass the release version}"

: "${MACOS_SIGNING_CERTIFICATE:?Add the base64 Developer ID .p12 to macos-release}"
: "${MACOS_SIGNING_CERTIFICATE_PASSWORD:?Add the .p12 password to macos-release}"
: "${APPLE_NOTARY_KEY:?Add the App Store Connect team API private key to macos-release}"
: "${APPLE_NOTARY_KEY_ID:?Add the App Store Connect key ID to macos-release}"
: "${APPLE_NOTARY_ISSUER_ID:?Add the App Store Connect issuer ID to macos-release}"

bundle_version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
if [[ "$bundle_version" != "$version" ]]; then
    echo "The built app version ($bundle_version) does not match the tag ($version)." >&2
    exit 1
fi

binary="$app/Contents/MacOS/On pace."
architectures=$(lipo -archs "$binary")
case "$architectures" in
    'arm64 x86_64'|'x86_64 arm64') ;;
    *) echo "Expected a universal app. Found $architectures." >&2; exit 1 ;;
esac

scratch_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/on-pace-signing.XXXXXX")
keychain="$scratch_dir/signing.keychain-db"
cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    rm -rf -- "$scratch_dir"
}
trap cleanup EXIT

keychain_password=$(openssl rand -hex 32)
printf '%s' "$MACOS_SIGNING_CERTIFICATE" | base64 -D > "$scratch_dir/certificate.p12"
printf '%s\n' "$APPLE_NOTARY_KEY" > "$scratch_dir/notary.p8"
security create-keychain -p "$keychain_password" "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security import "$scratch_dir/certificate.p12" -f pkcs12 -P "$MACOS_SIGNING_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign -k "$keychain"
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null

identity=$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/ {print $2; exit}')
if [[ -z "$identity" ]]; then
    echo 'The certificate must include a valid Developer ID Application identity and private key.' >&2
    exit 1
fi

# codesign requires the temporary keychain in the user search list.
user_keychains=$(security list-keychains -d user)
signing_keychains=("$keychain")
while IFS= read -r entry; do
    signing_keychains+=("$entry")
done < <(printf '%s\n' "$user_keychains" | sed -nE 's/^[[:space:]]*"(.*)"$/\1/p')
security list-keychains -d user -s "${signing_keychains[@]}"

# Sign Sparkle's nested code before sealing the enclosing framework and app.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign=(codesign --force --sign "$identity" --keychain "$keychain" --options runtime --timestamp)
"${sign[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
"${sign[@]}" --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
"${sign[@]}" "$sparkle/Versions/B/Autoupdate"
"${sign[@]}" "$sparkle/Versions/B/Updater.app"
"${sign[@]}" "$sparkle"
codesign --sign "$identity" --keychain "$keychain" --options runtime --timestamp "$app"
security delete-keychain "$keychain"

codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$scratch_dir/Notarization.zip"

notary_auth=(--key "$scratch_dir/notary.p8" --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID")
xcrun notarytool submit "$scratch_dir/Notarization.zip" "${notary_auth[@]}" \
    --wait --timeout 45m --output-format json > "$scratch_dir/notarization.json"
if ! jq -e '.status == "Accepted"' "$scratch_dir/notarization.json" >/dev/null; then
    cat "$scratch_dir/notarization.json" >&2
    submission_id=$(jq -r '.id' "$scratch_dir/notarization.json")
    xcrun notarytool log "$submission_id" "${notary_auth[@]}" >&2
    exit 1
fi

xcrun stapler staple "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
ditto -x -k "$zip" "$scratch_dir/extracted"
packaged_app="$scratch_dir/extracted/${app##*/}"
codesign --verify --deep --strict "$packaged_app"
xcrun stapler validate "$packaged_app"
spctl --assess --type execute --verbose "$packaged_app"
