#!/usr/bin/env bash
# Reel milestone 1 acceptance runner.
#
#   scripts/accept.sh offline
#
# Prints PASS, FAIL or SKIP for each criterion id and exits 1 on any FAIL. Everything runs
# headless: no window, no focus change, no sound, no network (deps.sh may download its pinned,
# sha256-verified tarballs on a cold checkout). Media comes only from build/fixtures.
#
#   AC01  scripts/check.sh: deps, fixtures, release build, tests, swiftlint, license check,
#         bundle, codesign verify, plutil lint, designated requirement.
#   AC02  reelctl seek-bench --json --runs 20 on the HEVC, H.264 and AV1 fixtures: every p95 at or
#         under its threshold, every exact seek on the expected frame, every sampled target at
#         least 35 dB PSNR. VP9 is run and printed, not gated.
#   AC03  reelctl av-sync --json on both sync fixtures: max |beep - flash| at most 20 ms over the
#         whole file and after 10 exact seeks, no audio renderer attached.
#   AC04  scripts/shots.sh: 8 PNGs at 2560x1440, not blank, light and dark controller regions
#         at least 40/255 apart, frontmost app unchanged, no on-screen window of the Reel PID.
#   AC05  swift test output has a passing suite for each of ResumeStoreTests, IINAWatchLaterTests,
#         SeekPlannerTests, KeyframeIndexTests, InputMapTests, PlayerModelTests,
#         ChromeVisibilityTests, OpenAndDropTests and SeekTests. A missing suite is a FAIL.
#
# Env: REEL_SCRATCH   SwiftPM scratch path (default <repo>/.build)
#      REEL_FIXTURES  fixture dir (default <repo>/build/fixtures)
#
# Every run uses build/accept/<timestamp>. The real Reel data folder, IINA's folders and the
# user's media are never read. Every process this script starts is stopped by PID on exit.

# shellcheck source=scripts/accept-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/accept-lib.sh"

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

GROUP=${1:-}
case "$GROUP" in
  offline) ;;
  *)
    usage
    exit 2
    ;;
esac

clear_reel_env
unset REEL_ALLOW_AUDIO REEL_FORCE_DECODER

SCRATCH="${REEL_SCRATCH:-$REPO/.build}"
FIXTURES="${REEL_FIXTURES:-$REPO/build/fixtures}"
export REEL_SCRATCH="$SCRATCH"
export REEL_FIXTURES="$FIXTURES"
APP="$REPO/build/bundle/Reel.app"
TOOLS="$REPO/build/shots/bin"

echo "Reel acceptance, group: $GROUP"
echo "Run folder: $RUN"

# Keep the Mac from idle sleep while the run lasts.
/usr/bin/caffeinate -i -w $$ &
track_pid $!

# The frontmost app as "asn name" on one line.
front() {
  local asn name
  asn="$(lsappinfo front 2>/dev/null || true)"
  name="$(lsappinfo info -only name "$asn" 2>/dev/null | head -1 || true)"
  echo "$asn $name"
}

# ---------------------------------------------------------------------------------------------
# AC01
# ---------------------------------------------------------------------------------------------

ac01() {
  : >"$RUN/ac01.start"
  if run_logged check "$REPO/scripts/check.sh"; then
    pass AC01 "scripts/check.sh exits 0"
  else
    fail AC01 "scripts/check.sh failed, see $LAST_LOG"
  fi
}

# ---------------------------------------------------------------------------------------------
# AC02 and AC03
# ---------------------------------------------------------------------------------------------

BIN_DIR=""
reelctl_path() {
  if [ -z "$BIN_DIR" ]; then
    BIN_DIR="$(swift build -c release --package-path "$REPO" --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null || true)"
  fi
  echo "$BIN_DIR/reelctl"
}

# run_ctl <name> <args...>: reelctl with a fresh REEL_HOME, no IINA folder and no audio. Standard
# output (the JSON report) goes to $RUN/<name>.json, standard error to $RUN/<name>.err.
run_ctl() {
  local name=$1 home rc
  shift
  home="$(fresh_home)"
  note "$name: reelctl $*"
  REEL_HOME="$home" REEL_IINA_WATCH_LATER="" "$CTL" "$@" >"$RUN/$name.json" 2>"$RUN/$name.err"
  rc=$?
  remove_run_path "$home"
  return $rc
}

# Reads a seek-bench report: gate <json> <first> <keyframe> <exact-worst>. Prints one summary line
# and exits 1 when anything is over its threshold or an exact seek missed.
eval_seek() {
  python3 -I -c '
import json, sys
report = json.load(open(sys.argv[1]))
limits = {"firstFrame": float(sys.argv[2]), "keyframeSeek": float(sys.argv[3]), "exactWorst": float(sys.argv[4])}
problems = []
parts = []
for key, limit in limits.items():
    p95 = (report.get(key) or {}).get("p95")
    parts.append("%s p95 %s/%g ms" % (key, "none" if p95 is None else "%.1f" % p95, limit))
    if p95 is None or p95 > limit:
        problems.append(key + " over limit")
checked = report.get("exactChecked", 0)
landed = report.get("exactLandedCorrect", 0)
parts.append("landed %d/%d" % (landed, checked))
if checked == 0 or landed != checked:
    problems.append("exact seeks landed on the wrong frame")
psnr = report.get("psnr") or []
low = [s for s in psnr if s.get("decibels") is None or s["decibels"] < 35]
known = [s["decibels"] for s in psnr if s.get("decibels") is not None]
parts.append("psnr min %s dB over %d" % ("none" if not known else "%.1f" % min(known), len(psnr)))
if not psnr or low:
    problems.append("psnr below 35 dB or missing")
if report.get("misses"):
    problems.append("%d misses" % len(report["misses"]))
if report.get("failures"):
    problems.append("failures: " + "; ".join(report["failures"]))
print(", ".join(parts) + ("  [" + "; ".join(problems) + "]" if problems else ""))
sys.exit(1 if problems else 0)
' "$@"
}

ac02() {
  local file spec name first key exact bad="" lines="" out rc
  for spec in "hevc10_1080p24.mkv 200 50 250" "h264_1080p30.mp4 200 50 350" "av1_2160p60.mkv 200 80 550"; do
    # shellcheck disable=SC2086
    set -- $spec
    name=$1 first=$2 key=$3 exact=$4
    file="$FIXTURES/$name"
    if [ ! -f "$file" ]; then
      bad="$bad [$name missing]"
      continue
    fi
    cat "$file" >/dev/null # warm the file cache; the media is our own fixture
    run_ctl "seek-$name" seek-bench "$file" --json --runs 20 || true
    out="$(eval_seek "$RUN/seek-$name.json" "$first" "$key" "$exact" 2>&1)"
    rc=$?
    note "$name: $out"
    lines="$lines [$name: $out]"
    [ $rc -eq 0 ] || bad="$bad [$name]"
  done
  if [ -f "$FIXTURES/vp9_2160p60.webm" ]; then
    run_ctl seek-vp9 seek-bench "$FIXTURES/vp9_2160p60.webm" --json --runs 20 || true
    note "vp9_2160p60.webm (not gated): $(python3 -I -c '
import json, sys
try:
    r = json.load(open(sys.argv[1]))
    print(", ".join("%s p95 %.1f ms" % (k, r[k]["p95"]) for k in ("firstFrame", "keyframeSeek", "exactWorst") if (r.get(k) or {}).get("p95") is not None))
except Exception as e:
    print("no report (%s)" % e)
' "$RUN/seek-vp9.json")"
  fi
  if [ -n "$bad" ]; then
    fail AC02 "seek thresholds not met:$bad;$lines"
  else
    pass AC02 "seek-bench p95s within thresholds:$lines"
  fi
}

eval_sync() {
  python3 -I -c '
import json, sys
report = json.load(open(sys.argv[1]))
limit = float(sys.argv[2])
problems = []
parts = []
for key in ("sequential", "afterSeeks"):
    phase = report.get(key) or {}
    worst = phase.get("maxAbsMilliseconds")
    parts.append("%s max %s ms over %d pairs" % (key, "none" if worst is None else "%.1f" % worst, phase.get("pairs", 0)))
    if worst is None or phase.get("pairs", 0) == 0 or worst > limit:
        problems.append(key + " over limit or empty")
parts.append("%d seeks" % report.get("seeks", 0))
if report.get("seeks", 0) < 10:
    problems.append("fewer than 10 seeks")
if report.get("failures"):
    problems.append("failures: " + "; ".join(report["failures"]))
print(", ".join(parts) + ("  [" + "; ".join(problems) + "]" if problems else ""))
sys.exit(1 if problems else 0)
' "$@"
}

ac03() {
  local name bad="" lines="" out rc
  for name in sync_h264_aac.mp4 sync_hevc_opus.mkv; do
    if [ ! -f "$FIXTURES/$name" ]; then
      bad="$bad [$name missing]"
      continue
    fi
    run_ctl "sync-$name" av-sync "$FIXTURES/$name" --json --seeks 10 || true
    out="$(eval_sync "$RUN/sync-$name.json" 20 2>&1)"
    rc=$?
    note "$name: $out"
    lines="$lines [$name: $out]"
    [ $rc -eq 0 ] || bad="$bad [$name]"
  done
  if [ -n "$bad" ]; then
    fail AC03 "A/V sync not met:$bad;$lines"
  else
    pass AC03 "A/V sync within 20 ms, silent:$lines"
  fi
}

# ---------------------------------------------------------------------------------------------
# AC04
# ---------------------------------------------------------------------------------------------

# The controller's pixel rectangle in a 1280x720 point shot at 2x: ControllerLayout.frame gives
# x 387.2, y 564.8, 480 x 76 points for the default position. If the layout moves, the light and
# dark regions stop differing and this criterion fails rather than passing silently.
CTRL_RECT="774 1130 960 152"

ac04() {
  local before after rc=0 problems="" scn mode f stats width height deviation light dark diff count=0
  if [ ! -x "$APP/Contents/MacOS/Reel" ]; then
    run_logged bundle "$REPO/scripts/bundle.sh" --release || true
  fi
  before="$(front)"
  run_logged shots "$REPO/scripts/shots.sh"
  rc=$?
  after="$(front)"
  if [ $rc -ne 0 ]; then
    case $rc in
      3) problems="$problems [frontmost app changed]" ;;
      4) problems="$problems [an on-screen window appeared]" ;;
      *) problems="$problems [shots.sh exit $rc, see $LAST_LOG]" ;;
    esac
  fi
  if [ "$before" != "$after" ]; then
    problems="$problems [lsappinfo front changed: $before -> $after]"
  fi
  for scn in empty playing paused-osd scrubbing; do
    for mode in light dark; do
      f="$REPO/build/shots/$scn-$mode.png"
      if [ ! -s "$f" ]; then
        problems="$problems [missing $scn-$mode.png]"
        continue
      fi
      stats="$("$TOOLS/shot-stats" "$f" 2>/dev/null || true)"
      width="$(echo "$stats" | awk '{print $1}')"
      height="$(echo "$stats" | awk '{print $2}')"
      deviation="$(echo "$stats" | awk '{print $4}')"
      if [ "$width" != 2560 ] || [ "$height" != 1440 ]; then
        problems="$problems [$scn-$mode is ${width:-?}x${height:-?}]"
      elif ! awk -v d="${deviation:-0}" 'BEGIN { exit !(d > 1.0) }'; then
        problems="$problems [$scn-$mode is blank, stddev ${deviation:-0}]"
      else
        count=$((count + 1))
      fi
    done
  done
  for scn in playing paused-osd scrubbing; do
    # shellcheck disable=SC2086
    light="$("$TOOLS/shot-stats" "$REPO/build/shots/$scn-light.png" $CTRL_RECT 2>/dev/null | awk '{print $3}')"
    # shellcheck disable=SC2086
    dark="$("$TOOLS/shot-stats" "$REPO/build/shots/$scn-dark.png" $CTRL_RECT 2>/dev/null | awk '{print $3}')"
    if [ -z "$light" ] || [ -z "$dark" ]; then
      problems="$problems [no controller stats for $scn]"
      continue
    fi
    diff="$(awk -v a="$light" -v b="$dark" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.1f", d }')"
    note "$scn controller luminance light $light dark $dark diff $diff"
    if ! awk -v d="$diff" 'BEGIN { exit !(d >= 40) }'; then
      problems="$problems [$scn controller light/dark differ by only $diff/255]"
    fi
  done
  if [ -n "$problems" ]; then
    fail AC04 "screenshots:$problems"
  else
    pass AC04 "$count PNGs at 2560x1440, not blank, light and dark controller differ, frontmost unchanged, no window"
  fi
}

# ---------------------------------------------------------------------------------------------
# AC05
# ---------------------------------------------------------------------------------------------

REQUIRED_SUITES="ResumeStoreTests IINAWatchLaterTests SeekPlannerTests KeyframeIndexTests InputMapTests PlayerModelTests ChromeVisibilityTests OpenAndDropTests SeekTests"

ac05() {
  local log="$REPO/build/check/test.log" suite problems="" n=0 summary
  # check.sh just ran swift test; use its log when it is from this run, else run the tests here.
  if [ ! -f "$log" ] || [ ! "$log" -nt "$RUN/ac01.start" ]; then
    local home
    home="$(fresh_home)"
    REEL_HOME="$home" REEL_IINA_WATCH_LATER="" run_logged swift-test \
      caffeinate -i swift test --package-path "$REPO" --scratch-path "$SCRATCH" || true
    remove_run_path "$home"
    log="$RUN/swift-test.log"
  fi
  if grep -q '^✘' "$log"; then
    problems="$problems [a test or suite failed]"
  fi
  for suite in $REQUIRED_SUITES; do
    if grep -qE "^✔ Suite \"?$suite\"? passed" "$log"; then
      n=$((n + 1))
    elif grep -qE "^✘ Suite \"?$suite\"? failed" "$log"; then
      problems="$problems [$suite failed]"
    else
      problems="$problems [$suite missing]"
    fi
  done
  summary="$(grep -E '^[✔✘] Test run with' "$log" | tail -1 || true)"
  case "$summary" in
    "✔ Test run with"*) ;;
    *) problems="$problems [no passing test run summary]" ;;
  esac
  if [ -n "$problems" ]; then
    fail AC05 "suites:$problems"
  else
    pass AC05 "$n required suites passed; ${summary#✔ }"
  fi
}

# ---------------------------------------------------------------------------------------------
# offline
# ---------------------------------------------------------------------------------------------

group_offline() {
  echo
  echo "== offline"
  ac01
  CTL="$(reelctl_path)"
  if [ -x "$CTL" ]; then
    ac02
    ac03
  else
    fail AC02 "no reelctl at $CTL"
    fail AC03 "no reelctl at $CTL"
  fi
  ac04
  ac05
}

group_offline

echo
FAILS="$(awk -F'\t' '$2 == "FAIL"' "$RESULTS" | wc -l | tr -d ' ')"
PASSES="$(awk -F'\t' '$2 == "PASS"' "$RESULTS" | wc -l | tr -d ' ')"
echo "Results: $RESULTS ($PASSES PASS, $FAILS FAIL)"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
