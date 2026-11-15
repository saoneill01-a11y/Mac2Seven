#!/bin/bash
# Wraps a signed, notarized Mac2Seven.app in a disk image for the website download, then signs,
# notarizes and staples the disk image itself so Gatekeeper accepts it with no extra steps.
#
#   Tools/make-dmg.sh <path to Mac2Seven.app> <output .dmg>
#
# The window shows the app next to an Applications shortcut, so people drag it straight in.
# (Sparkle keeps using the zip for automatic updates; the disk image is only for first installs.)
set -euo pipefail

APP="$1"
DMG="$2"
IDENTITY="Developer ID Application: Cyber Support IT LLC (Z6U97H9M93)"
NOTARY_PROFILE="Mac2Seven-notary"

spctl --assess --type execute "$APP" || { echo "Error: $APP isn't notarized yet" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Mac2Seven.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "Mac2Seven" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "Notarizing the disk image (usually a few minutes)"
RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
echo "$RESULT" | grep -E "id:|status:" | tail -2
echo "$RESULT" | grep -q "status: Accepted" || { echo "Error: the disk image was not notarized" >&2; exit 1; }
xcrun stapler staple -q "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
