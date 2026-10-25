#!/usr/bin/env bash
# All gates (design section 14). Exits 0 only when every gate passes.
#   deps (stamp) -> fixtures (stamp) -> swift build -c release -> swift test -> swiftlint --strict
#   -> license check via reelctl probe --build-info -> reelctl does not link Sparkle ->
#   scripts/bundle.sh -> codesign --verify --deep --strict -> plutil -lint (bundle id, document
#   types, folder usage string) -> Sparkle in the bundle (framework, feed, key, @rpath link) ->
#   designated requirement names dev.sdusteric.reel -> no em or en dashes
#
# Env: REEL_SCRATCH  SwiftPM scratch path (default <repo>/.build). Agents building in parallel
#                    pass their own, e.g. REEL_SCRATCH=$TMPDIR/reel-check.
#      REEL_FIXTURES fixture dir (default <repo>/build/fixtures)
# Tests run with a fresh REEL_HOME, IINA carry-over disabled and audio output disallowed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${REEL_SCRATCH:-$ROOT/.build}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
LOGDIR="$ROOT/build/check"
mkdir -p "$LOGDIR"

TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/reel-check-home.XXXXXX")"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT
export REEL_HOME="$TMP_HOME"
# Sparkle never starts under the gates (app-updates CONTRACT.md).
export REEL_NO_UPDATES=1
export REEL_IINA_WATCH_LATER=""
unset REEL_ALLOW_AUDIO REEL_FORCE_DECODER

gate() { # gate <name> <command...>: runs the command, output to build/check/<name>.log
  local name="$1"; shift
  local log="$LOGDIR/$name.log"
  local t0; t0=$(date +%s)
  printf '%-10s ' "$name"
  if "$@" >"$log" 2>&1; then
    echo "ok ($(( $(date +%s) - t0 )) s)"
  else
    echo "FAIL ($(( $(date +%s) - t0 )) s), log: $log"
    tail -40 "$log"
    exit 1
  fi
}

build_release() {
  caffeinate -i swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH"
}

run_tests() {
  local status=0
  caffeinate -i swift test --package-path "$ROOT" --scratch-path "$SCRATCH" || status=$?
  [ "$status" = 0 ] || return "$status"
  if grep -q '✘' "$LOGDIR/test.log"; then echo "a test reported a failure"; return 1; fi
}

run_lint() {
  (cd "$ROOT" && swiftlint lint --strict --quiet)
}

license_check() {
  local info
  info="$("$SCRATCH/release/reelctl" probe --build-info)"
  echo "$info"
  grep -q '^license: LGPL version 2.1 or later$' <<<"$info" || { echo "license is not LGPL 2.1 or later"; return 1; }
  if grep -qE -- '--enable-(gpl|nonfree)' <<<"$info"; then echo "GPL or nonfree component enabled"; return 1; fi
}

APP="$ROOT/build/bundle/Reel.app"
# app-updates CONTRACT.md
FEED_URL="https://sdusteric.github.io/app-updates/reel/appcast.xml"
ED_KEY="PMaW+8sZRzOkfIwy1KBGk0CHTVoN49FE9o8gUlNGdZc="

cli_no_sparkle() {
  local bin="$SCRATCH/release/reelctl" linked
  [ -x "$bin" ] || { echo "missing $bin"; return 1; }
  linked="$(otool -L "$bin")"
  if grep -qi sparkle <<<"$linked"; then echo "$linked"; echo "reelctl links Sparkle"; return 1; fi
  echo "reelctl does not link Sparkle"
}

bundle_app() {
  REEL_SCRATCH="$SCRATCH" caffeinate -i "$ROOT/scripts/bundle.sh" --release
}

codesign_check() {
  codesign --verify --deep --strict --verbose=2 "$APP"
}

plist_check() {
  plutil -lint "$APP/Contents/Info.plist" || return 1
  local id
  id="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")"
  [ "$id" = dev.sdusteric.reel ] || { echo "bundle id is $id"; return 1; }
  # M2: Reel is listed as a viewer for the container formats, and the folder-access prompt for
  # next and previous episode has its usage string.
  local types="$LOGDIR/document-types.json"
  plutil -extract CFBundleDocumentTypes json -o "$types" "$APP/Contents/Info.plist" \
    || { echo "CFBundleDocumentTypes missing"; return 1; }
  python3 -I -c '
import json, sys
types = json.load(open(sys.argv[1]))
bad = []
for ext in ("mkv", "webm", "mp4", "mov", "avi", "flv"):
    ranks = [t.get("LSHandlerRank") for t in types if ext in [e.lower() for e in t.get("CFBundleTypeExtensions", [])]]
    print(ext, ",".join(str(x) for x in ranks) or "missing")
    if not ranks or any(x != "Default" for x in ranks):
        bad.append(ext)
if bad:
    print("document types lack LSHandlerRank Default for: " + " ".join(bad))
    sys.exit(1)
' "$types" || return 1
  local usage
  usage="$(plutil -extract NSDocumentsFolderUsageDescription raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
  [ -n "$usage" ] || { echo "NSDocumentsFolderUsageDescription missing"; return 1; }
  echo "NSDocumentsFolderUsageDescription: $usage"
}

sparkle_check() {
  local plist="$APP/Contents/Info.plist" feed key linked
  [ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || { echo "Sparkle.framework missing from the bundle"; return 1; }
  feed="$(plutil -extract SUFeedURL raw -o - "$plist" 2>/dev/null || true)"
  [ "$feed" = "$FEED_URL" ] || { echo "SUFeedURL is '$feed', expected $FEED_URL"; return 1; }
  key="$(plutil -extract SUPublicEDKey raw -o - "$plist" 2>/dev/null || true)"
  [ "$key" = "$ED_KEY" ] || { echo "SUPublicEDKey is '$key', expected $ED_KEY"; return 1; }
  linked="$(otool -L "$APP/Contents/MacOS/Reel")"
  grep -q '@rpath/Sparkle.framework' <<<"$linked" || { echo "$linked"; echo "Reel does not link @rpath/Sparkle.framework"; return 1; }
  otool -l "$APP/Contents/MacOS/Reel" | grep -q 'path @executable_path/../Frameworks ' \
    || { echo "Reel lacks rpath @executable_path/../Frameworks"; return 1; }
  echo "Sparkle.framework bundled, SUFeedURL $feed, SUPublicEDKey matches, Reel links @rpath/Sparkle.framework"
}

requirement_check() {
  local requirement
  requirement="$(codesign -d -r- "$APP" 2>&1)"
  echo "$requirement"
  grep -q 'identifier "dev.sdusteric.reel"' <<<"$requirement" || { echo "designated requirement lacks dev.sdusteric.reel"; return 1; }
}

dash_check() {
  # Swift files are covered by swiftlint; this covers prose, scripts and resources.
  local paths=() path hits
  for path in docs scripts resources CLAUDE.md README.md Package.swift .swiftlint.yml .gitignore; do
    [ -e "$ROOT/$path" ] && paths+=("$ROOT/$path")
  done
  hits="$(LC_ALL=C grep -rnIE $'\xe2\x80\x93|\xe2\x80\x94' "${paths[@]}" || true)"
  if [ -n "$hits" ]; then echo "$hits"; echo "em or en dash found"; return 1; fi
  echo "no em or en dashes in ${#paths[@]} paths"
}

T0=$(date +%s)
gate deps caffeinate -i "$ROOT/scripts/deps.sh"
gate fixtures caffeinate -i "$ROOT/scripts/fixtures.sh"
gate build build_release
gate test run_tests
gate lint run_lint
gate license license_check
gate no-sparkle cli_no_sparkle
gate bundle bundle_app
gate codesign codesign_check
gate plist plist_check
gate sparkle sparkle_check
gate requirement requirement_check
gate dashes dash_check
echo "all gates passed ($(( $(date +%s) - T0 )) s)"
