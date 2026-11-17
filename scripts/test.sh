#!/bin/bash
# Usage: scripts/test.sh [name-substring-filter]
# Builds each module with -enable-testing, builds one test executable per
# Tests/<Module>Tests directory (TestKit + tests + generated main.swift), runs them.
# main.swift is generated: it calls every `func registerXxxTests()` found in the test files.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
FILTER="${1:-}"
ARCH="$(uname -m)"
OUT="$ROOT/.build/test"
TARGET="$ARCH-apple-macos13"
rm -rf "$OUT"; mkdir -p "$OUT"

swiftc -target "$TARGET" -Onone -enable-testing -parse-as-library -module-name SafeNetCore \
  -emit-module -emit-module-path "$OUT/SafeNetCore.swiftmodule" \
  -emit-library -static -o "$OUT/libSafeNetCore.a" \
  $(find Sources/SafeNetCore -name '*.swift')
swiftc -target "$TARGET" -Onone -enable-testing -parse-as-library -module-name SafeNetUI -I "$OUT" \
  -emit-module -emit-module-path "$OUT/SafeNetUI.swiftmodule" \
  -emit-library -static -o "$OUT/libSafeNetUI.a" \
  $(find Sources/SafeNetUI -name '*.swift')

STATUS=0
TOTAL=0
for dir in Tests/*Tests; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  mkdir -p "$OUT/gen_$name"; main="$OUT/gen_$name/main.swift"
  { echo "// generated"; grep -h -o 'func register[A-Za-z0-9_]*Tests()' "$dir"/*.swift | sed -e 's/^func //' -e 's/^/    /' || true; } > "$OUT/gen_$name/list"
  { echo "import Foundation"; sed 's/$//' "$OUT/gen_$name/list" | tail -n +2; echo "runAllTests()"; } > "$main"
  echo "==> building $name"
  swiftc -target "$TARGET" -Onone -module-name "$name" -I "$OUT" -L "$OUT" \
    -lSafeNetUI -lSafeNetCore -o "$OUT/$name" \
    Tests/TestKit/TestKit.swift "$dir"/*.swift "$main"
  echo "==> running $name"
  set +e
  if [ -n "$FILTER" ]; then "$OUT/$name" "$FILTER" > "$OUT/$name.log" 2>&1; RC=$?; else "$OUT/$name" > "$OUT/$name.log" 2>&1; RC=$?; fi
  set -e
  cat "$OUT/$name.log"
  N="$(sed -n 's/^Executed \([0-9]*\) tests.*/\1/p' "$OUT/$name.log" | tail -n 1)"
  if [ -z "$N" ]; then
    if [ "$RC" -gt 128 ]; then WHY="killed by signal $((RC - 128))"; else WHY="exit code $RC"; fi
    echo "!!! TEST BINARY $name ABNORMAL EXIT ($WHY): no 'Executed N tests' line; the run is incomplete" >&2
    STATUS=1; continue
  fi
  [ "$RC" = 0 ] || STATUS=1
  TOTAL=$((TOTAL + N))
done
[ "$TOTAL" -gt 0 ] || { echo "No tests executed"; STATUS=1; }
exit $STATUS
