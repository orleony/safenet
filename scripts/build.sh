#!/bin/bash
# Build SafeNet with plain swiftc (no SwiftPM / Xcode needed).
# Usage: scripts/build.sh [--universal]
# Output: .build/release/<arch>/..., final executable at .build/SafeNetApp
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
UNIVERSAL=0
[ "${1:-}" = "--universal" ] && UNIVERSAL=1

build_arch() {
  local arch="$1"; local out="$ROOT/.build/release/$arch"
  local target="$arch-apple-macos13"
  mkdir -p "$out"
  echo "==> [$arch] SafeNetCore"
  swiftc -target "$target" -O -parse-as-library -module-name SafeNetCore \
    -emit-module -emit-module-path "$out/SafeNetCore.swiftmodule" \
    -emit-library -static -o "$out/libSafeNetCore.a" \
    $(find Sources/SafeNetCore -name '*.swift')
  echo "==> [$arch] SafeNetUI"
  swiftc -target "$target" -O -parse-as-library -module-name SafeNetUI -I "$out" \
    -emit-module -emit-module-path "$out/SafeNetUI.swiftmodule" \
    -emit-library -static -o "$out/libSafeNetUI.a" \
    $(find Sources/SafeNetUI -name '*.swift')
  echo "==> [$arch] SafeNetApp"
  swiftc -target "$target" -O -module-name SafeNetApp -I "$out" -L "$out" \
    -lSafeNetUI -lSafeNetCore -o "$out/SafeNetApp" \
    $(find Sources/SafeNetApp -name '*.swift')
}

if [ "$UNIVERSAL" = 1 ]; then
  build_arch x86_64
  build_arch arm64
  echo "==> lipo"
  lipo -create .build/release/x86_64/SafeNetApp .build/release/arm64/SafeNetApp -output .build/SafeNetApp
  lipo -info .build/SafeNetApp
else
  build_arch "$(uname -m)"
  cp ".build/release/$(uname -m)/SafeNetApp" .build/SafeNetApp
fi
echo "Built .build/SafeNetApp"
