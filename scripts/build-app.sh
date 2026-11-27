#!/bin/bash
# Build the distributable SafeNet.app (universal x86_64 + arm64, ad-hoc signed) and SafeNet.zip.
# Usage: scripts/build-app.sh [--dev]
#   --dev  developer build: no update feed / key in Info.plist (the self-updater is off, so a
#          test build is never replaced by a release), SafeNetChannel=dev, version x.y.z-dev shown.
# Output (dist/ is a build artefact, not committed):
#   dist/SafeNet.app            the app (Contents/MacOS/SafeNetApp is also the watchdog and the CLI)
#   dist/safenet                console command (shell wrapper that runs the app's binary in CLI mode)
#   dist/ПРОЧТИ-МЕНЯ.txt        first-launch notes (Russian + short English)
#   dist/SafeNet.zip            SafeNet/{SafeNet.app, ПРОЧТИ-МЕНЯ.txt}, made with ditto (keeps signature)
# Nothing is installed anywhere: no /Applications, no /usr/local, no login item.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 2
DEV=0
[ "${1:-}" = "--dev" ] && DEV=1
ROOT="$PWD"
DIST="$ROOT/dist"
APP="$DIST/SafeNet.app"
README_NAME="ПРОЧТИ-МЕНЯ.txt"

echo "==> universal build"
scripts/build.sh --universal

echo "==> icon"
mkdir -p .build/icon
swiftc -O -o .build/icon/make-icon scripts/make-icon.swift
.build/icon/make-icon .build/icon/AppIcon.iconset .build/icon/preview.png
iconutil -c icns -o .build/icon/AppIcon.icns .build/icon/AppIcon.iconset

echo "==> bundle"
[ -n "$DIST" ] && [ "$DIST" = "$ROOT/dist" ] && [ "$ROOT" != / ] || exit 2
rm -rf -- "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/SafeNetApp "$APP/Contents/MacOS/SafeNetApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp .build/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/safenet "$APP/Contents/Resources/safenet"
chmod 755 "$APP/Contents/MacOS/SafeNetApp" "$APP/Contents/Resources/safenet"
# Version: the VERSION file (x.y.z) -> CFBundleShortVersionString, and x*10000+y*100+z -> CFBundleVersion.
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^([0-9]+)\.([0-9]{1,2})\.([0-9]{1,2})$ ]] || { echo "VERSION must be x.y.z (y, z < 100), got '$VERSION'" >&2; exit 2; }
BUILD=$(( BASH_REMATCH[1] * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[3]} ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
if [ "$DEV" = 1 ]; then
  /usr/libexec/PlistBuddy -c "Delete :SafeNetUpdateFeed" -c "Delete :SafeNetUpdatePublicKey" \
    -c "Add :SafeNetChannel string dev" "$APP/Contents/Info.plist"
  echo "DEV build: self-updater off"
fi
echo "version $VERSION (build $BUILD)"
plutil -lint "$APP/Contents/Info.plist"

echo "==> sign (ad-hoc, hardened runtime)"
# No Developer ID: ad-hoc signature ("-"). The hardened runtime is accepted with an ad-hoc
# signature and does not restrict anything SafeNet does (system libraries only, no JIT, no
# DYLD_* variables, no plug-ins). Extended attributes would break the seal: strip them first.
xattr -cr "$APP"
codesign --force --deep --sign - --options runtime --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|Signature)' || true
lipo -info "$APP/Contents/MacOS/SafeNetApp"

echo "==> CLI wrapper and notes"
cp Resources/safenet "$DIST/safenet"
chmod 755 "$DIST/safenet"
cp "Resources/$README_NAME" "$DIST/$README_NAME"

echo "==> zip"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/snstage.XXXXXX")" || { echo "mktemp failed" >&2; exit 2; }
# Never let an empty or odd STAGE turn the cleanup into a delete of something else.
case "$(basename -- "${STAGE:-/}")" in snstage.?*) ;; *) echo "bad stage dir '$STAGE'" >&2; exit 2;; esac
[ -d "$STAGE" ] || exit 2
trap 'case "$(basename -- "${STAGE:-/}")" in snstage.?*) [ -d "$STAGE" ] && rm -rf -- "$STAGE";; esac' EXIT
mkdir "$STAGE/SafeNet"
ditto "$APP" "$STAGE/SafeNet/SafeNet.app"
cp "Resources/$README_NAME" "$STAGE/SafeNet/$README_NAME"
xattr -cr "$STAGE/SafeNet"
ditto -c -k --keepParent "$STAGE/SafeNet" "$DIST/SafeNet.zip"
( cd "$DIST" && shasum -a 256 SafeNet.zip | tee SafeNet.zip.sha256 )
echo "Done: $APP, $DIST/safenet, $DIST/SafeNet.zip"
