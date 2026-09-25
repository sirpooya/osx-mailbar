#!/usr/bin/env bash
# Cut a Mailbar release: bump, build, zip, sign for Sparkle, tag, publish, update the appcast.
#
#   scripts/release.sh 1.1.0
#
# The `release` skill runs this (`.release.json` releaseCommand) after it has moved the changelog
# to [<version>] and committed it, so the tree must be clean. Everything is local: the EdDSA
# private key is in the login Keychain (account "mailbar"), never in the tree.
#
# Order matters: the zip is on GitHub Releases before appcast.xml names it, so an installed copy
# never reads a feed whose download is not there yet.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v${VERSION}"
REPO="sirpooya/osx-mailbar"
ZIP_NAME="Mailbar-${VERSION}.zip"
ZIP="build/${ZIP_NAME}"
APP=".dd/Build/Products/Release/Mailbar.app"
BIN=".dd/SourcePackages/artifacts/sparkle/Sparkle/bin"

cd "$(dirname "$0")/.."

[[ -z "$(git status --porcelain)" ]] || { echo "error: the tree is not clean" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && { echo "error: ${TAG} exists" >&2; exit 1; }
python3 scripts/changelog-notes.py --version "$VERSION" --format markdown >/dev/null

# Sparkle compares CFBundleVersion, so the build number goes up by one every release.
BUILD=$(( $(sed -n 's/^ *CURRENT_PROJECT_VERSION: *//p' project.yml) + 1 ))
sed -i '' -E "s/^( *MARKETING_VERSION:).*/\1 ${VERSION}/; s/^( *CURRENT_PROJECT_VERSION:).*/\1 ${BUILD}/" project.yml

echo "== Building ${VERSION} (${BUILD})"
xcodegen generate >/dev/null
xcodebuild -project Mailbar.xcodeproj -scheme Mailbar -configuration Release -derivedDataPath .dd build \
    | grep -E "error:|\*\* BUILD" || true
[[ -d "$APP" ]] || { echo "error: no Release build" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")" == "$VERSION" ]] \
    || { echo "error: the build does not report ${VERSION}" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")" == "$BUILD" ]] \
    || { echo "error: the build does not report build ${BUILD}" >&2; exit 1; }
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || { echo "error: Sparkle is not embedded" >&2; exit 1; }
codesign --verify --strict --deep "$APP"

# ditto, never zip -r: zip mangles the symlinks inside Sparkle.framework.
mkdir -p build
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Prints: sparkle:edSignature="..." length="..."
SIG_OUTPUT=$("$BIN/sign_update" --account mailbar "$ZIP")
SIGNATURE=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIG_OUTPUT")
LENGTH=$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"$SIG_OUTPUT")
[[ -n "$SIGNATURE" && -n "$LENGTH" ]] || { echo "error: sign_update gave no signature" >&2; exit 1; }

echo "== Tagging ${TAG}"
git add project.yml Mailbar/Info.plist
git commit -q -m "Bump version to ${VERSION} (${BUILD})"
git tag -a "$TAG" -m "Mailbar ${VERSION}"
git push -q origin HEAD:main "$TAG"

echo "== Publishing"
NOTES_MD=$(mktemp)
python3 scripts/changelog-notes.py --version "$VERSION" --format markdown >"$NOTES_MD"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Mailbar ${VERSION}" \
    --notes-file "$NOTES_MD" --verify-tag
rm -f "$NOTES_MD"

echo "== Appcast"
python3 scripts/update-appcast.py --tag "$TAG" --short-version "$VERSION" --build-version "$BUILD" \
    --min-system 14.0 --zip-name "$ZIP_NAME" --length "$LENGTH" --signature "$SIGNATURE" \
    --repo "$REPO" --notes "$(python3 scripts/changelog-notes.py --version "$VERSION" --format html)"
git add appcast.xml
git commit -q -m "Appcast for ${VERSION}"
git push -q origin HEAD:main

echo "== Released ${TAG}: https://github.com/${REPO}/releases/tag/${TAG}"
