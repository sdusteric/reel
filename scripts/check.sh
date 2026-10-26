#!/usr/bin/env bash
# All gates (design section 14). Exits 0 only when every gate passes.
#   deps (stamp) -> fixtures (stamp) -> swift build -c release -> swift test -> swiftlint --strict
#   -> license check via reelctl probe --build-info -> av-sync (both sync fixtures, 20 ms, M1 3 and
#   M3 1) -> soak-smoke (12 corpus files through reelctl soak, M3 1) -> reelctl does not link Sparkle ->
#   scripts/bundle.sh -> codesign --verify --deep --strict -> plutil -lint (bundle id, document
#   types, folder usage string) -> Sparkle in the bundle (framework, feed, key, @rpath link) ->
#   designated requirement names dev.sdusteric.reel -> no em or en dashes
#
# Env: REEL_SCRATCH  SwiftPM scratch path (default <repo>/.build). Agents building in parallel
#                    pass their own, e.g. REEL_SCRATCH=$TMPDIR/reel-check.
#      REEL_FIXTURES fixture dir (default <repo>/build/fixtures)
# av-sync and soak-smoke run reelctl with a fresh REEL_HOME each and never attach an audio renderer.
# Tests run with a fresh REEL_HOME, IINA carry-over disabled and audio output disallowed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${REEL_SCRATCH:-$ROOT/.build}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
FIXTURES="${REEL_FIXTURES:-$ROOT/build/fixtures}"
LOGDIR="$ROOT/build/check"
mkdir -p "$LOGDIR"

TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/reel-check-home.XXXXXX")"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT
export REEL_HOME="$TMP_HOME"
# Sparkle never starts under the gates (app-updates CONTRACT.md).
export REEL_NO_UPDATES=1
export REEL_IINA_WATCH_LATER=""
# At most 8 test cases at once (Swift Testing's experimental width; ignored if unsupported). With
# every case started together, the synchronous decode cases and ~25 engines' blocked feeders held
# all cooperative threads for the first seconds, and the async timing checks beside them failed.
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-8}"
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

# A fresh REEL_HOME for one reelctl run; prints its path. Removed by remove_ctl_home, which only
# deletes a directory that mktemp made here.
ctl_home() { mktemp -d "${TMPDIR:-/tmp}/reel-check-ctl.XXXXXX"; }
remove_ctl_home() {
  case "$1" in
    "${TMPDIR:-/tmp}"/reel-check-ctl.?*) [ -d "$1" ] && rm -rf -- "$1" ;;
  esac
  return 0
}

# Both sync fixtures: max |beep - flash| at most 20 ms over the whole file and after 10 exact
# seeks, at least 10 seeks, no failures. reelctl attaches no audio renderer (REEL_ALLOW_AUDIO is
# unset above).
av_sync_check() {
  local ctl="$SCRATCH/release/reelctl" name home report rc bad=0
  [ -x "$ctl" ] || { echo "missing $ctl"; return 1; }
  for name in sync_h264_aac.mp4 sync_hevc_opus.mkv; do
    if [ ! -f "$FIXTURES/$name" ]; then echo "$name missing in $FIXTURES"; bad=1; continue; fi
    home="$(ctl_home)"
    report="$LOGDIR/av-sync-$name.json"
    REEL_HOME="$home" "$ctl" av-sync "$FIXTURES/$name" --json --seeks 10 >"$report" 2>"$LOGDIR/av-sync-$name.err"
    rc=$?
    remove_ctl_home "$home"
    if [ "$rc" -ne 0 ]; then echo "$name: reelctl av-sync exit $rc"; tail -5 "$LOGDIR/av-sync-$name.err"; bad=1; continue; fi
    python3 -I -c '
import json, sys
report = json.load(open(sys.argv[1]))
problems = []
parts = []
for key in ("sequential", "afterSeeks"):
    phase = report.get(key) or {}
    worst = phase.get("maxAbsMilliseconds")
    parts.append("%s max %s ms over %d pairs" % (key, "none" if worst is None else "%.1f" % worst, phase.get("pairs", 0)))
    if worst is None or phase.get("pairs", 0) == 0 or worst > 20:
        problems.append(key + " over 20 ms or empty")
parts.append("%d seeks" % report.get("seeks", 0))
if report.get("seeks", 0) < 10:
    problems.append("fewer than 10 seeks")
if report.get("failures"):
    problems.append("failures: " + "; ".join(report["failures"]))
print(sys.argv[2] + ": " + ", ".join(parts) + ("  [" + "; ".join(problems) + "]" if problems else ""))
sys.exit(1 if problems else 0)
' "$report" "$name" || bad=1
  done
  return "$bad"
}

# Twelve corpus files, every base at least once (trunc50 of each of the 8 bases, plus a zero-filled
# middle, a 4 KB overwrite at 50%, a bit-flip file and a 4 KB head), through reelctl soak: no
# crash, no hang, no mismatch against corpus/manifest.json. The full corpus is acceptance's job.
SOAK_SMOKE_FILES=(
  av1.trunc50.mkv flv1.trunc50.flv h264.trunc50.ts h264_faststart.trunc50.mp4
  h264_moov_end.trunc50.mp4 hevc.trunc50.mkv mpeg4.trunc50.avi vp9.trunc50.webm
  hevc.zeromid.mkv h264_faststart.overwrite50.mp4 vp9.bitflip1.webm av1.head4k.mkv
)

soak_smoke_check() {
  local ctl="$SCRATCH/release/reelctl" home report rc name files=()
  [ -x "$ctl" ] || { echo "missing $ctl"; return 1; }
  for name in "${SOAK_SMOKE_FILES[@]}"; do
    [ -f "$FIXTURES/corpus/$name" ] || { echo "corpus/$name missing in $FIXTURES"; return 1; }
    files+=("$FIXTURES/corpus/$name")
  done
  home="$(ctl_home)"
  report="$LOGDIR/soak-smoke.json"
  REEL_HOME="$home" "$ctl" soak --list "${files[@]}" --seed 1 --ops 20 --json >"$report" 2>"$LOGDIR/soak-smoke.err"
  rc=$?
  remove_ctl_home "$home"
  if [ ! -s "$report" ]; then echo "reelctl soak exit $rc, no report"; tail -10 "$LOGDIR/soak-smoke.err"; return 1; fi
  python3 -I -c '
import json, sys
report = json.load(open(sys.argv[1]))
t = report.get("totals") or {}
expected = int(sys.argv[2])
print("%d files, crashes %s, hangs %s, mismatches %s, leaks %s (not gated), played %s, classified %s, longest operation %.0f ms" % (
    t.get("files", 0), t.get("crashes"), t.get("hangs"), t.get("mismatches"), t.get("leaks"),
    t.get("played"), t.get("classified"), t.get("longestOperationMs", 0)))
bad = [f for f in report.get("files", []) if f.get("problems")]
for f in bad:
    print("  %s: %s" % (f.get("file", "?").rsplit("/", 1)[-1], "; ".join(f["problems"])))
failed = t.get("files") != expected or t.get("crashes") != 0 or t.get("hangs") != 0 or t.get("mismatches") != 0
sys.exit(1 if failed else 0)
' "$report" "${#files[@]}"
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
  local scheme actions
  scheme="$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
  [ "$scheme" = reel ] || { echo "CFBundleURLTypes scheme is '$scheme', expected reel"; return 1; }
  actions="$(plutil -extract SDShelfActions json -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
  [ "$actions" = '["open-recent","check-for-updates"]' ] || { echo "SDShelfActions is '$actions'"; return 1; }
  echo "URL scheme reel, SDShelfActions $actions"
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
gate av-sync av_sync_check
gate soak-smoke soak_smoke_check
gate no-sparkle cli_no_sparkle
gate bundle bundle_app
gate codesign codesign_check
gate plist plist_check
gate sparkle sparkle_check
gate requirement requirement_check
gate dashes dash_check
echo "all gates passed ($(( $(date +%s) - T0 )) s)"
