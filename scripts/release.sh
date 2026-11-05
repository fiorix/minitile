#!/bin/bash
# Build a signed, notarized and stapled release: build/release/minitile.dmg and its SHA-256.
#
# Usage: scripts/release.sh VERSION
#
# Signing uses MINITILE_SIGN_IDENTITY (default "Developer ID Application") from the keychain.
# Notarization uses either NOTARY_PROFILE (a notarytool keychain profile, for local releases) or
# NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID (an App Store Connect API key, for CI).
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: scripts/release.sh VERSION}
export MINITILE_SIGN_IDENTITY=${MINITILE_SIGN_IDENTITY:-Developer ID Application}
out=build/release
app=build/Minitile.app
dmg=$out/minitile.dmg

notarize() {
    local credentials result status id
    if [ -n "${NOTARY_PROFILE:-}" ]; then credentials=(--keychain-profile "$NOTARY_PROFILE")
    else credentials=(--key "${NOTARY_KEY_PATH:?}" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}"); fi
    result=$(xcrun notarytool submit "$1" "${credentials[@]}" --wait --output-format json)
    status=$(plutil -extract status raw -o - - <<<"$result")
    id=$(plutil -extract id raw -o - - <<<"$result")
    echo "Notarization of $(basename "$1"): $status ($id)"
    if [ "$status" != Accepted ]; then
        xcrun notarytool log "$id" "${credentials[@]}" || true
        return 1
    fi
}

MINITILE_CHANNEL=release MINITILE_CONFIGURATION=release MINITILE_HARDENED=1 MINITILE_VERSION=$version \
    MINITILE_BUILD=${MINITILE_BUILD:-1} scripts/build-app.sh
rm -rf "$out"
mkdir -p "$out"

# The app is notarized and stapled first, so it carries its ticket once copied out of the disk image.
ditto -c -k --keepParent "$app" "$out/Minitile.zip"
notarize "$out/Minitile.zip"
xcrun stapler staple "$app"
rm "$out/Minitile.zip"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Minitile.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "minitile $version" -srcfolder "$stage" -fs APFS -format UDZO -ov "$dmg"
codesign --force --sign "$MINITILE_SIGN_IDENTITY" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"

spctl --assess --type execute --verbose "$app"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
(cd "$out" && shasum -a 256 minitile.dmg > minitile.dmg.sha256)
printf '%s\n' "$PWD/$dmg" "$PWD/$out/minitile.dmg.sha256"
