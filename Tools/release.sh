#!/bin/bash
# Builds, signs, notarizes and (optionally) publishes a Mac2Seven release with a Sparkle update feed.
#
#   Tools/release.sh             Dry run: build, sign, notarize, staple and make dist/vX.Y/ — nothing is uploaded.
#   Tools/release.sh --publish   The same, then create the GitHub release with the disk image and appcast.xml.
#
# One signed, notarized disk image is used for both: Sparkle installs updates from Mac2Seven-X.Y.dmg, and
# websites link to the same file under the fixed name Mac2Seven.dmg.
#
# Before a release: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml (the build number
# must go up every time; Sparkle uses it to compare versions), write Tools/release-notes/vX.Y.md,
# commit and push.
#
# Needs, on this Mac: the Developer ID certificate, the "Mac2Seven-notary" notarytool profile, and the
# Sparkle private key saved under the "Mac2Seven" keychain account (Sparkle's generate_keys).
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=false
[[ "${1:-}" == "--publish" ]] && PUBLISH=true

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Mac2Seven-cli"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
IDENTITY="Developer ID Application: Cyber Support IT LLC (Z6U97H9M93)"
NOTARY_PROFILE="Mac2Seven-notary"
KEY_ACCOUNT="Mac2Seven"
REPO="saoneill01-a11y/Mac2Seven"

VERSION=$(sed -nE 's/^ *MARKETING_VERSION: "(.*)"/\1/p' project.yml | head -1)
BUILD=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "(.*)"/\1/p' project.yml | head -1)
TAG="v$VERSION"
NOTES="Tools/release-notes/$TAG.md"
OUT="dist/$TAG"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nError: %s\n' "$*" >&2; exit 1; }

step "Mac2Seven $VERSION (build $BUILD)"
if $PUBLISH; then
    [[ -f "$NOTES" ]] || fail "write release notes in $NOTES first"
    [[ -z "$(git status --porcelain)" ]] || fail "commit your changes first (the release is tagged at the pushed commit)"
    git fetch -q origin
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "push main first"
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then fail "$TAG is already published"; fi
fi

step "Building Release"
xcodegen generate -q
xcodebuild -project Mac2Seven.xcodeproj -scheme Mac2Seven -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$DERIVED" clean build -quiet
APP="$DERIVED/Build/Products/Release/Mac2Seven.app"

step "Signing (Sparkle's helpers first, then the app)"
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign --entitlements Mac2Seven/Mac2Seven.entitlements "$APP"
codesign --verify --deep --strict "$APP"
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q get-task-allow; then
    fail "the app still has the get-task-allow entitlement"
fi

step "Notarizing (usually a few minutes)"
rm -rf "$OUT"; mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/upload.zip"
RESULT=$(xcrun notarytool submit "$OUT/upload.zip" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
echo "$RESULT" | grep -E "id:|status:" | tail -2
echo "$RESULT" | grep -q "status: Accepted" || fail "notarization was not accepted (see: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)"
rm "$OUT/upload.zip"

step "Stapling and checking Gatekeeper"
xcrun stapler staple -q "$APP"
spctl --assess --type execute "$APP"
step "Making the disk image"
DMG="$OUT/Mac2Seven-$VERSION.dmg"
Tools/make-dmg.sh "$APP" "$DMG"

step "Writing the update feed (signed with your Sparkle key)"
"$SPARKLE_BIN/generate_appcast" --account "$KEY_ACCOUNT" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --full-release-notes-url "https://github.com/$REPO/releases/tag/$TAG" \
    --link "https://github.com/$REPO" \
    -o "$OUT/appcast.xml" "$OUT"
grep -q "sparkle:edSignature" "$OUT/appcast.xml" || fail "appcast.xml has no update signature"
grep -q "Mac2Seven-$VERSION.dmg" "$OUT/appcast.xml" || fail "appcast.xml doesn't point to the disk image"
# Same disk image under a fixed name, so websites can link to .../releases/latest/download/Mac2Seven.dmg
mkdir -p "$OUT/stable" && cp "$DMG" "$OUT/stable/Mac2Seven.dmg"
shasum -a 256 "$DMG"

if ! $PUBLISH; then
    step "Dry run finished: $OUT (run with --publish to release it)"
    exit 0
fi

step "Publishing $TAG on GitHub"
gh release create "$TAG" --repo "$REPO" --target main --title "Mac2Seven $VERSION" --notes-file "$NOTES" \
    "$DMG" "$OUT/stable/Mac2Seven.dmg" "$OUT/appcast.xml"
step "Published: https://github.com/$REPO/releases/tag/$TAG"
