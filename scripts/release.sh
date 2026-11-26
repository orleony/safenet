#!/bin/bash
# SafeNet releases with signed self-updates.
#
#   scripts/release.sh keygen              one time: create the signing key and put its PUBLIC
#                                          key into Resources/Info.plist (commit that change)
#   scripts/release.sh build <x.y.z>       write VERSION, build, produce dist/release/:
#                                          SafeNet-<x.y.z>.zip, update.json, update.json.sig
#   scripts/release.sh publish <x.y.z>     push the release tag after committing VERSION.
#                                         GitHub Actions builds, signs and publishes the release.
#
# The private key lives in $SAFENET_SIGNING_KEY (default ~/.config/safenet/update-signing.key),
# never in the repository. Losing it means installed apps can no longer verify new releases:
# keep a backup. Release notes: $SAFENET_RELEASE_NOTES (text) or the commit subjects since the
# previous tag.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 2
ROOT="$PWD"
KEY="${SAFENET_SIGNING_KEY:-$HOME/.config/safenet/update-signing.key}"
TOOL="$ROOT/.build/update-tool/update-tool"
OUT="$ROOT/dist/release"
PLIST="$ROOT/Resources/Info.plist"

build_tool() {
  mkdir -p "$(dirname "$TOOL")"
  swiftc -O -o "$TOOL" scripts/update-tool.swift
}

check_version() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]{1,2}\.[0-9]{1,2}$ ]] || { echo "version must be x.y.z (y, z < 100)" >&2; exit 2; }
}

repo_slug() {
  # owner/name from the feed URL in Info.plist (https://github.com/<owner>/<name>/releases/...).
  local feed; feed="$(/usr/libexec/PlistBuddy -c 'Print :SafeNetUpdateFeed' "$PLIST")"
  [[ "$feed" =~ ^https://github\.com/([^/]+/[^/]+)/releases/ ]] || { echo "SafeNetUpdateFeed is not a GitHub releases URL: $feed" >&2; exit 2; }
  echo "${BASH_REMATCH[1]}"
}

cmd="${1:-}"
case "$cmd" in
  keygen)
    build_tool
    PUB="$("$TOOL" keygen "$KEY")"
    /usr/libexec/PlistBuddy -c "Set :SafeNetUpdatePublicKey $PUB" "$PLIST"
    echo "Private key: $KEY (mode 0600, back it up, never commit it)"
    echo "Public key written to Resources/Info.plist: $PUB"
    ;;
  build)
    VER="${2:-}"; check_version "$VER"
    build_tool
    [ -f "$KEY" ] || { echo "no signing key at $KEY: run scripts/release.sh keygen first" >&2; exit 2; }
    PUB="$(/usr/libexec/PlistBuddy -c 'Print :SafeNetUpdatePublicKey' "$PLIST")"
    [ "$PUB" = "$("$TOOL" pubkey "$KEY")" ] || { echo "the key in Info.plist does not match $KEY" >&2; exit 2; }
    if [ -n "$(git status --porcelain --untracked-files=no -- Sources Resources scripts)" ]; then
      echo "uncommitted changes in Sources/Resources/scripts: commit them first (the release must match a commit)" >&2; exit 2
    fi
    echo "$VER" > VERSION
    scripts/fetch-singbox.sh          # tests run every generated VPN config through `sing-box check`
    scripts/test.sh
    scripts/build-app.sh
    SLUG="$(repo_slug)"
    rm -rf -- "$OUT"; mkdir -p "$OUT"
    ZIP="SafeNet-$VER.zip"
    cp dist/SafeNet.zip "$OUT/$ZIP"
    SHA="$(shasum -a 256 "$OUT/$ZIP" | awk '{print $1}')"
    SIZE="$(stat -f %z "$OUT/$ZIP")"
    if [ -n "${SAFENET_RELEASE_NOTES:-}" ]; then NOTES="$SAFENET_RELEASE_NOTES"
    else
      PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
      NOTES="$(git log --format='- %s' ${PREV:+"$PREV"..HEAD} | head -n 30)"
    fi
    /usr/bin/python3 - "$OUT/update.json" "$VER" "https://github.com/$SLUG/releases/download/v$VER/$ZIP" "$SHA" "$SIZE" "$NOTES" <<'PY'
import json, sys
path, ver, url, sha, size, notes = sys.argv[1:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"version": ver, "url": url, "sha256": sha, "size": int(size),
               "minimum_system": "13.0", "notes": notes}, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    "$TOOL" sign "$KEY" "$OUT/update.json" > "$OUT/update.json.sig"
    "$TOOL" verify "$PUB" "$OUT/update.json" "$OUT/update.json.sig" || { echo "signature self-check failed" >&2; exit 1; }
    echo "Release $VER ready in dist/release/ ($ZIP, update.json, update.json.sig)."
    echo "VERSION now says $VER: commit it, then run: scripts/release.sh publish $VER"
    ;;
  publish)
    VER="${2:-}"; check_version "$VER"
    [ "$(cat VERSION)" = "$VER" ] || { echo "Set VERSION to $VER and commit first" >&2; exit 2; }
    git diff --quiet HEAD || { echo "Commit the release changes before tagging" >&2; exit 2; }
    git tag -a "v$VER" -m "SafeNet $VER"
    git push origin "v$VER"
    echo "Tag pushed. GitHub Actions builds and publishes the signed release."
    ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
