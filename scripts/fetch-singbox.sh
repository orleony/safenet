#!/bin/bash
# Downloads the pinned sing-box release (both architectures), checks SHA-256, unpacks into
# vendor/sing-box/ as one universal binary plus its LICENSE. Idempotent: skips when present.
# sing-box (https://github.com/SagerNet/sing-box) is GPL-3.0; SafeNet runs it as a separate
# program and ships its license and a link to its source next to it.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 2
VERSION="1.14.4"
SHA_ARM64="0d8c7f5ed5d587b0f1a5e9772a708ec3bfa4ac4c9329604b01d8d9c2ba406838"
SHA_AMD64="eae86b9b033bba50b7c44ab719e4bfac0aca05efd28483390ed3aa510f32db25"
OUT="vendor/sing-box"
if [ -x "$OUT/sing-box" ] && [ "$(cat "$OUT/VERSION" 2>/dev/null)" = "$VERSION" ]; then
  echo "sing-box $VERSION already in $OUT"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for arch in arm64 amd64; do
  name="sing-box-$VERSION-darwin-$arch"
  url="https://github.com/SagerNet/sing-box/releases/download/v$VERSION/$name.tar.gz"
  curl -fsSL --max-time 300 -o "$TMP/$arch.tgz" "$url"
  if [ "$arch" = arm64 ]; then want="$SHA_ARM64"; else want="$SHA_AMD64"; fi
  got="$(shasum -a 256 "$TMP/$arch.tgz" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || { echo "sing-box $arch: SHA-256 mismatch ($got)" >&2; exit 1; }
  mkdir -p "$TMP/$arch"; tar -xzf "$TMP/$arch.tgz" -C "$TMP/$arch"
done
rm -rf "$OUT"; mkdir -p "$OUT"
lipo -create "$TMP/arm64/sing-box-$VERSION-darwin-arm64/sing-box" "$TMP/amd64/sing-box-$VERSION-darwin-amd64/sing-box" \
  -output "$OUT/sing-box"
chmod 755 "$OUT/sing-box"
cp "$TMP/arm64/sing-box-$VERSION-darwin-arm64/LICENSE" "$OUT/LICENSE"
echo "$VERSION" > "$OUT/VERSION"
echo "sing-box $VERSION: $OUT/sing-box ($(lipo -archs "$OUT/sing-box"))"
