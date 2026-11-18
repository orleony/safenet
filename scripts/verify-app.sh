#!/bin/bash
# Automated end-to-end check of the built SafeNet.app (run scripts/build-app.sh first).
# Usage: scripts/verify-app.sh [path/to/SafeNet.app]   (default: dist/SafeNet.app)
#
# Safety: runs the app ONLY in test mode (SAFENET_FAKE_IP) with a TEMPORARY SAFENET_CONFIG_DIR;
# the only protected "app" is a throwaway copy of /bin/sleep in that temp dir (matched by its full
# path). The real ~/Library/Application Support/SafeNet and real apps are never touched. Every
# process it starts is resumed and killed on exit; the temp dir is removed. Exit code != 0 on any
# failed check.
#        scripts/verify-app.sh --selftest-guard   (checks only the temp-dir deletion guard)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
ROOT="$(pwd -P)"
[ -n "$ROOT" ] && [ "$ROOT" != / ] || exit 2
HOME_REAL="$(cd "$HOME" 2>/dev/null && pwd -P)"

# --- temp-dir guard -------------------------------------------------------------------------
# tmp_ok PATH: true only for an existing, absolute directory whose resolved path has a basename
# starting with "snverify." and is neither equal to, an ancestor of, nor inside the repository
# or $HOME (nor "/"). Every recursive delete of the temp dir goes through safe_rm_tmp.
tmp_ok() {
    local p="${1:-}" r b x
    [ -n "$p" ] || return 1
    case "$p" in /*) ;; *) return 1;; esac
    [ -d "$p" ] || return 1
    r="$(cd -P -- "$p" 2>/dev/null && pwd -P)" || return 1
    [ -n "$r" ] && [ "$r" != / ] || return 1
    b="$(basename -- "$r")"
    case "$b" in snverify.?*) ;; *) return 1;; esac
    for x in "$ROOT" "$HOME_REAL"; do
        [ -n "$x" ] || return 1
        [ "$r" = "$x" ] && return 1
        case "$r/" in "$x"/*) return 1;; esac      # inside x
        case "$x/" in "$r"/*) return 1;; esac      # ancestor of x
    done
    return 0
}
safe_rm_tmp() {
    if tmp_ok "${1:-}"; then rm -rf -- "$1"; return 0; fi
    echo "verify-app: REFUSING to delete '${1:-}' (not a snverify.* temp dir)" >&2
    return 1
}

if [ "${1:-}" = "--selftest-guard" ]; then
    SF=0
    expect() { # $1 = accept|reject, $2 = label, $3 = path
        if tmp_ok "$3"; then got=accept; else got=reject; fi
        if [ "$got" = "$1" ]; then echo "  ok   guard $1s $2"; else echo "  FAIL guard should $1 $2 ('$3')"; SF=$((SF + 1)); fi
    }
    GOOD="$(mktemp -d "${TMPDIR:-/tmp}/snverify.XXXXXX")" || exit 2
    BADNAME="$(mktemp -d "${TMPDIR:-/tmp}/othername.XXXXXX")" || exit 2
    INREPO="$ROOT/.build/snverify.selftest"; mkdir -p "$INREPO" || exit 2
    LINK="$GOOD/snverify.link"; ln -s "$ROOT" "$LINK"
    expect reject "an empty path" ""
    expect reject "the repository" "$ROOT"
    expect reject "\$HOME" "$HOME"
    expect reject "/" "/"
    expect reject "a relative path" "snverify.rel"
    expect reject "a missing directory" "${TMPDIR:-/tmp}/snverify.missing-$$"
    expect reject "a temp dir without the prefix" "$BADNAME"
    expect reject "a snverify.* dir inside the repository" "$INREPO"
    expect reject "a snverify.* symlink to the repository" "$LINK"
    expect reject "the parent of the repository" "$(dirname "$ROOT")"
    expect accept "a fresh snverify.* temp dir" "$GOOD"
    # Remove the fixtures without any recursive delete of a rejected path.
    rm -f "$LINK"; rmdir "$INREPO" "$BADNAME"
    safe_rm_tmp "$GOOD" && [ ! -e "$GOOD" ] && echo "  ok   safe_rm_tmp removed the valid temp dir" \
        || { echo "  FAIL safe_rm_tmp on the valid temp dir"; SF=$((SF + 1)); }
    D="$(mktemp -d "${TMPDIR:-/tmp}/othername.XXXXXX")" || exit 2
    if safe_rm_tmp "$D" 2>/dev/null; then echo "  FAIL safe_rm_tmp accepted '$D'"; SF=$((SF + 1))
    else [ -d "$D" ] && echo "  ok   safe_rm_tmp refused (and kept) a non-prefixed dir"; fi
    rmdir "$D"
    [ $SF = 0 ] && { echo "guard selftest: PASSED"; exit 0; }
    echo "guard selftest: $SF FAILED"; exit 1
fi
APP="${1:-$ROOT/dist/SafeNet.app}"
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
EXE="$APP/Contents/MacOS/SafeNetApp"
CLI="$(dirname "$APP")/safenet"
[ -x "$CLI" ] || CLI="$APP/Contents/Resources/safenet"
REAL_DIR="$HOME/Library/Application Support/SafeNet"

FAILS=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi; }
# Every call that might hang runs under a hard timeout (SIGALRM, exit 142).
to() { local secs="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"; }

[ -x "$EXE" ] || { echo "no app at $APP (run scripts/build-app.sh)"; exit 2; }
REAL_BEFORE="$( [ -e "$REAL_DIR" ] && ls -la "$REAL_DIR" 2>/dev/null | md5 || echo absent)"

echo "== static checks: $APP"
check "codesign --verify --deep --strict" to 60 codesign --verify --deep --strict "$APP"
SIG="$(codesign -dv "$APP" 2>&1)"
echo "$SIG" | grep -q '^Signature=adhoc' && pass "ad-hoc signature" || fail "ad-hoc signature"
echo "$SIG" | grep -q '^Identifier=local.safenet.app' && pass "signing identifier local.safenet.app" || fail "signing identifier"
echo "$SIG" | grep -q 'flags=.*runtime' && pass "hardened runtime flag" || fail "hardened runtime flag"
ARCHS="$(lipo -archs "$EXE" 2>/dev/null)"
[ "$ARCHS" = "x86_64 arm64" ] && pass "lipo archs: $ARCHS" || fail "lipo archs: '$ARCHS' (want 'x86_64 arm64')"
PL="$APP/Contents/Info.plist"
check "plutil -lint Info.plist" plutil -lint "$PL"
key() { plutil -extract "$1" raw -o - "$PL" 2>/dev/null; }
for kv in CFBundleIdentifier=local.safenet.app CFBundleName=SafeNet CFBundleDisplayName=SafeNet \
          CFBundleExecutable=SafeNetApp CFBundlePackageType=APPL CFBundleShortVersionString=1.0.0 \
          CFBundleVersion=1 LSMinimumSystemVersion=13.0 LSUIElement=true NSHighResolutionCapable=true \
          NSPrincipalClass=NSApplication CFBundleIconFile=AppIcon \
          LSApplicationCategoryType=public.app-category.utilities; do
    k="${kv%%=*}"; v="${kv#*=}"; got="$(key "$k")"
    [ "$got" = "$v" ] && pass "Info.plist $k = $v" || fail "Info.plist $k = '$got' (want '$v')"
done
if plutil -p "$PL" | grep -q 'UsageDescription'; then fail "no usage-description keys"; else pass "no usage-description keys"; fi
check "AppIcon.icns present" test -s "$APP/Contents/Resources/AppIcon.icns"
check "CLI wrapper executable" test -x "$CLI"
if xattr -r "$APP" 2>/dev/null | grep -q .; then fail "no extended attributes in bundle"; else pass "no extended attributes in bundle"; fi

echo "== runtime checks (test mode, temp config dir)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/snverify.XXXXXX")" || { echo "verify-app: mktemp failed"; exit 2; }
[ -n "$TMP" ] || { echo "verify-app: mktemp returned nothing"; exit 2; }
TMP="$(cd -P -- "$TMP" && pwd -P)" || exit 2
tmp_ok "$TMP" || { echo "verify-app: unsafe temp dir '$TMP'"; exit 2; }
CFG="$TMP/cfg"; mkdir -p "$CFG"
SLEEPER="$TMP/snsleeper"
cp /bin/sleep "$SLEEPER"
APP_PID=""; SLEEP_PID=""
export SAFENET_CONFIG_DIR="$CFG"
export SAFENET_FAKE_IP="1.2.3.4,RU"

watchdogs() { pgrep -f -- "--watchdog [0-9]+ $CFG/" 2>/dev/null; }
cleanup() {
    [ -n "$SLEEP_PID" ] && kill -CONT "$SLEEP_PID" 2>/dev/null
    [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null
    for p in $(watchdogs); do kill -9 "$p" 2>/dev/null; done
    [ -n "$SLEEP_PID" ] && { kill -CONT "$SLEEP_PID" 2>/dev/null; kill -9 "$SLEEP_PID" 2>/dev/null; }
    wait 2>/dev/null
    safe_rm_tmp "$TMP" || FAILS=$((FAILS + 1))
}
trap 'cleanup; [ $FAILS = 0 ] || exit 1' EXIT
trap 'exit 130' INT TERM

# Reap the app after it was asked to exit: never block on a process that refused to die.
reap_app() {
    if wait_for 10 dead "$APP_PID"; then wait "$APP_PID" 2>/dev/null
    else kill -9 "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; fi
    APP_PID=""
}

write_config() { # $1 = allowed countries (space separated)
    { echo "apps: []"
      echo "custom_apps:"
      echo "  - name: snsleeper"
      echo "    match: $SLEEPER"
      echo "allow:"
      echo "  countries:"
      for c in $1; do echo "    - $c"; done
      echo "grace: 10m"
      echo "check_interval: 1"
    } > "$CFG/config.tmp" && mv "$CFG/config.tmp" "$CFG/config.yaml"
}
stat_of() { ps -o stat= -p "$1" 2>/dev/null | tr -d ' '; }
wait_for() { # $1 = seconds, rest = command
    local n=$(( $1 * 10 )); shift
    while [ $n -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done; return 1
}
is_stopped() { case "$(stat_of "$SLEEP_PID")" in T*) return 0;; *) return 1;; esac; }
is_running() { case "$(stat_of "$SLEEP_PID")" in S*|R*) return 0;; *) return 1;; esac; }
alive() { kill -0 "$1" 2>/dev/null; }
dead() { ! kill -0 "$1" 2>/dev/null; }
no_watchdog() { [ -z "$(watchdogs)" ]; }
start_app() {
    "$EXE" >>"$TMP/app.log" 2>&1 &
    APP_PID=$!
}
SOCK="$CFG/safenet.sock"

write_config "NL"
"$SLEEPER" 3600 &
SLEEP_PID=$!
sleep 0.3
is_running && pass "sleeper started (pid $SLEEP_PID)" || fail "sleeper started"

# 1. Launch from the bundle: frozen, watchdog child, journal, events, socket.
start_app
wait_for 15 is_stopped && pass "sleeper frozen after launch (stat $(stat_of "$SLEEP_PID"))" \
                       || fail "sleeper frozen after launch (stat $(stat_of "$SLEEP_PID"))"
WD="$(watchdogs | head -n 1)"
if [ -n "$WD" ] && [ "$(ps -o ppid= -p "$WD" | tr -d ' ')" = "$APP_PID" ]; then
    pass "watchdog $WD is a direct child of the app ($APP_PID)"
else fail "watchdog child of the app (found '$WD')"; fi
grep -qE "\"pid\" *: *$SLEEP_PID[^0-9]" "$CFG/frozen.json" 2>/dev/null \
    && pass "journal frozen.json lists the sleeper" || fail "journal frozen.json lists the sleeper"
wait_for 5 grep -q '"frozen"' "$CFG/events.jsonl" && pass "events.jsonl has a 'frozen' event" \
                                                 || fail "events.jsonl has a 'frozen' event"
wait_for 5 test -S "$SOCK" && pass "socket created" || fail "socket created"
MODE="$(stat -f '%Lp' "$SOCK" 2>/dev/null)"; [ "$MODE" = 600 ] && pass "socket mode 0600" || fail "socket mode '$MODE'"

# 2. CLI over the socket.
OUT="$(to 10 "$CLI" status 2>&1)"; RC=$?
echo "$OUT" | sed 's/^/       | /'
[ $RC = 0 ] && pass "safenet status exit 0" || fail "safenet status exit $RC"
for s in "Приложения заморожены" "ТЕСТОВЫЙ РЕЖИМ" "IP: 1.2.3.4 (RU)" "snsleeper: заморожено"; do
    echo "$OUT" | grep -qF "$s" && pass "status contains '$s'" || fail "status contains '$s'"
done
OUT="$(to 10 "$CLI" version 2>&1)"; [ "$OUT" = "SafeNet 1.0.0" ] && pass "safenet version: $OUT" || fail "safenet version: '$OUT'"
OUT="$(to 10 "$CLI" config 2>&1)"; [ "$OUT" = "$CFG/config.yaml" ] && pass "safenet config = temp config" || fail "safenet config: '$OUT'"
OUT="$(to 10 "$CLI" panel 2>&1)"; RC=$?
[ $RC = 0 ] && [ "$OUT" = "Окно SafeNet открыто" ] && pass "safenet panel: $OUT (a visible panel window exists)" || fail "safenet panel: rc $RC '$OUT'"
to 10 "$CLI" bogus >/dev/null 2>&1; RC=$?; [ $RC = 2 ] && pass "unknown command exit 2" || fail "unknown command exit $RC"
OUT="$(to 10 "$CLI" allow RU 2>&1)"; RC=$?
[ $RC = 0 ] && echo "$OUT" | grep -qF "Разрешена страна RU" && pass "safenet allow RU: $OUT" || fail "safenet allow RU: rc $RC '$OUT'"
wait_for 10 is_running && pass "sleeper resumed after allow RU" || fail "sleeper resumed after allow RU (stat $(stat_of "$SLEEP_PID"))"
grep -q -- "- RU" "$CFG/config.yaml" && pass "config.yaml now allows RU" || fail "config.yaml now allows RU"
OUT="$(to 10 "$CLI" status 2>&1)"; echo "$OUT" | grep -qF "Защита включена" && pass "status: Защита включена" || fail "status after allow: '$OUT'"

# 3. Hot reload: removing RU from the file freezes again; a broken file keeps the old settings.
write_config "NL"
wait_for 10 is_stopped && pass "hot reload (RU removed) froze the sleeper again" || fail "hot reload re-freeze"
printf 'allow: [unclosed\n  bad: : :\n' > "$CFG/config.tmp" && mv "$CFG/config.tmp" "$CFG/config.yaml"
sleep 3
is_stopped && alive "$APP_PID" && pass "broken config.yaml: app alive, sleeper still frozen (old settings)" \
           || fail "broken config.yaml handling"
write_config "NL"; sleep 1

# 4. SIGTERM: resumes, removes the socket, watchdog exits.
kill -TERM "$APP_PID"
wait_for 10 dead "$APP_PID" && pass "app exited on SIGTERM" || fail "app exited on SIGTERM"
reap_app
wait_for 5 is_running && pass "sleeper resumed on SIGTERM" || fail "sleeper resumed on SIGTERM"
wait_for 5 test ! -e "$SOCK" && pass "socket removed on exit" || fail "socket removed on exit"
wait_for 5 no_watchdog && pass "watchdog gone" || fail "watchdog gone"
grep -qE "\"pid\" *: *$SLEEP_PID[^0-9]" "$CFG/frozen.json" 2>/dev/null && fail "journal cleared on exit" || pass "journal cleared on exit"
to 10 "$CLI" status >/dev/null 2>&1; RC=$?; [ $RC = 3 ] && pass "status when not running: exit 3" || fail "status when not running: exit $RC"

# 5. kill -9: the watchdog resumes the sleeper.
start_app
wait_for 15 is_stopped && pass "relaunch froze the sleeper" || fail "relaunch froze the sleeper"
wait_for 5 test -S "$SOCK"
WD="$(watchdogs | head -n 1)"
kill -9 "$APP_PID"; reap_app
wait_for 10 is_running && pass "kill -9: watchdog resumed the sleeper" || fail "kill -9: watchdog resumed the sleeper"
wait_for 10 no_watchdog && pass "kill -9: watchdog exited afterwards" || fail "kill -9: watchdog still running ($WD)"
to 10 "$CLI" status >/dev/null 2>&1; RC=$?; [ $RC = 3 ] && pass "stale socket after kill -9: status exit 3" || fail "stale socket: status exit $RC"

# 6. Restart over the stale socket works, then clean SIGTERM.
start_app
wait_for 15 is_stopped && pass "start over a stale socket: frozen again" || fail "start over a stale socket"
OUT="$(to 10 "$CLI" status 2>&1)"; echo "$OUT" | grep -qF "Приложения заморожены" && pass "CLI works after stale socket" || fail "CLI after stale socket: '$OUT'"
kill -TERM "$APP_PID"; reap_app
wait_for 5 is_running && pass "final SIGTERM resumed the sleeper" || fail "final SIGTERM resume"
wait_for 5 no_watchdog && wait_for 5 test ! -e "$SOCK" && pass "final: no watchdog, no socket" || fail "final: leftovers"

if grep -qiE 'fatal error|crash|exception' "$TMP/app.log"; then
    fail "app log has no crash lines"; sed 's/^/       | /' "$TMP/app.log" | tail -20
else pass "app log has no crash lines"; fi

# The real config dir must be exactly as before.
REAL_AFTER="$( [ -e "$REAL_DIR" ] && ls -la "$REAL_DIR" 2>/dev/null | md5 || echo absent)"
[ "$REAL_BEFORE" = "$REAL_AFTER" ] && pass "real config dir untouched ($REAL_AFTER)" || fail "real config dir changed!"

kill -9 "$SLEEP_PID" 2>/dev/null; wait "$SLEEP_PID" 2>/dev/null; SLEEP_PID=""
cleanup; trap - EXIT
LEFT="$(pgrep -f "$TMP" 2>/dev/null)"
[ -z "$LEFT" ] && pass "no leftover processes" || { fail "leftover processes: $LEFT"; }

echo
if [ $FAILS = 0 ]; then echo "verify-app: ALL CHECKS PASSED"; exit 0; fi
echo "verify-app: $FAILS CHECK(S) FAILED"; exit 1
