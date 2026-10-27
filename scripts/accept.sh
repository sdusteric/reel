#!/usr/bin/env bash
# Reel acceptance runner (milestones 1, 2 and 3).
#
#   scripts/accept.sh offline    M1 criteria AC01 to AC05, then the M2 group, then the M3 group
#   scripts/accept.sh m2         only the M2 group (AC-M2-1 to AC-M2-6)
#   scripts/accept.sh m3         only the M3 group (AC-M3-1 to AC-M3-10)
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
#   AC04  scripts/shots.sh for the M1 four: 8 PNGs at 2560x1440, not blank, light and dark
#         controller regions at least 40/255 apart, frontmost app unchanged, no on-screen window.
#   AC05  swift test output has a passing suite for each of ResumeStoreTests, IINAWatchLaterTests,
#         SeekPlannerTests, KeyframeIndexTests, InputMapTests, PlayerModelTests,
#         ChromeVisibilityTests, OpenAndDropTests, SeekTests and the M2 and M3 suites. A missing
#         suite is a FAIL.
#
# M2 (design section 16):
#   AC-M2-1  scripts/check.sh exits 0 (reused from AC01 in the same run), and Info.plist lists
#            document types for mkv, webm, mp4, mov, avi and flv with LSHandlerRank Default and
#            has NSDocumentsFolderUsageDescription.
#   AC-M2-2  reelctl subs: sidecar chosen, embedded 简英双语 with --no-external, ink, glyphs,
#            a CJK face from the fallback list (PingFang, else Hiragino Sans GB), position, silence between events, GB18030 and Big5 text, PGS
#            rectangle within 2 px, render p95 at most 16 ms, and the three subtitle suites.
#   AC-M2-3  reelctl thumbs on four fixtures (budgets, setup, count, width, blankness, reload) and
#            the HEVC seek thresholds with thumbnails generating.
#   AC-M2-4  reelctl episodes order, and the EpisodeList and AutoAdvance tests by name.
#   AC-M2-5  scripts/shots.sh (all 28 scenarios in light and dark, shared with AC-M3-6): the 30 PNGs
#            of M2's 15 scenarios by name at 2560x1440, not blank, controller regions differ,
#            outlined subtitle ink, frontmost app unchanged.
#   AC-M2-6  VP9 hybrid seek-bench thresholds, and M1's AC02 and AC03 passing in the same run.
#
# M3 (design section 16):
#   AC-M3-1  scripts/check.sh exits 0 with the av-sync and soak-smoke gates in its output, and
#            every M1 and M2 criterion passes (offline only; alone, m3 notes that they did not run).
#   AC-M3-2  reelctl hdr on the six ramp files with --decoder hw and sw: kind, decoded codes,
#            attachments, MDCV and CLL, tone-mapped and screenshot patches, thumbnail; the SDR
#            control; the plan for 3 displays x 3 settings; five suites.
#   AC-M3-3  Dolby Vision: probe profile and compatibility, dv81 codes against the PQ ramp, dv84
#            HLG base, dv5 note, tag and warning; two suites and the NAL types 62 and 63 test.
#   AC-M3-4  reelctl energy-bench: play, paused and occluded budgets, zero counters while paused,
#            resync at most 300 ms; EnergyTests.
#   AC-M3-5  reelctl soak on corpus/ and odd/: no crash, hang or leak, no mismatch, copy for every
#            problem, dataEnd and damage checks; an AddressSanitizer build on 24 files (scratch
#            $TMPDIR/reel-asan, deleted afterwards); RobustnessTests and OddFileTests.
#   AC-M3-6  the 8 M3 scenarios in light and dark (16 PNGs among the 48): size, not blank, region
#            luma difference, the 203-nit patch of hdr-badge, frontmost app, no window.
#   AC-M3-7  named tests for Shift+Cmd+O, Cmd+I, the v OSD, output device choice and the Settings
#            rows; reelctl devices lists a default device.
#   AC-M3-8  reelctl color --frame 12 on the three sdr/ bar files, hw and sw: every patch within 3
#            codes of AVAssetImageGenerator, the attachments (BT.709, untagged HD as BT.709,
#            untagged SD as SMPTE 170M), an ICC profile in the screenshot; ColorPipelineTests.
#   AC-M3-9  reelctl hdr --display-headroom 1.0 on the PQ and HLG ramps: toneMapToSDR, reference
#            white 225 to 255, the ramp strictly increasing to 1000 nits, black at most 8; 4.0
#            gives edr; the runtime display change test.
#   AC-M3-10 the named MotionTests (Reduce Motion branches, clamped anchor, drop target, chrome
#            reveal timing) and design 15.2 saying the subtitle lift snaps.
#
# Env: REEL_SCRATCH   SwiftPM scratch path (default <repo>/.build)
#      REEL_FIXTURES  fixture dir (default <repo>/build/fixtures)
#
# Every run uses build/accept/<timestamp>. The real Reel data folder, IINA's folders and the
# user's media are never read. Every process this script starts is stopped by PID on exit.

# shellcheck source=scripts/accept-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/accept-lib.sh"

usage() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

GROUP=${1:-}
case "$GROUP" in
  offline | m2 | m3) ;;
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
# The same test width as check.sh, for the swift test runs here.
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-8}"
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

# check.sh runs once per accept run; AC01 and AC-M2-1 both read its result.
CHECK_RC=""
CHECK_LOG=""
run_check_once() {
  [ -z "$CHECK_RC" ] || return 0
  : >"$RUN/ac01.start"
  run_logged check "$REPO/scripts/check.sh"
  CHECK_RC=$?
  CHECK_LOG="$LAST_LOG"
}

ac01() {
  run_check_once
  if [ "$CHECK_RC" -eq 0 ]; then
    pass AC01 "scripts/check.sh exits 0"
  else
    fail AC01 "scripts/check.sh failed, see $CHECK_LOG"
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
  run_logged shots "$REPO/scripts/shots.sh" empty playing paused-osd scrubbing
  rc=$?
  after="$(front)"
  if [ $rc -ne 0 ]; then
    case $rc in
      3) problems="$problems [frontmost app changed]" ;;
      4) problems="$problems [an on-screen window appeared]" ;;
      5) problems="$problems [a shot process registered as an application]" ;;
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
M2_SUITES="SubtitleRenderTests SubtitleCharsetDecodeTests BitmapSubtitleTests EpisodeListTests AutoAdvanceTests"
M3_SUITES="HDRDecodeTests HDRToneMapTests DynamicRangePlanTests DynamicRangeLayerTests DolbyVisionPolicyTests DolbyVisionProbeTests EnergyPolicyTests EnergyTests MediaProblemTests RobustnessTests OddFileTests OutputDeviceChoiceTests OutputDeviceTests AudioOutputDevicesTests DynamicRangeTagTests FailureStateTests VideoInfoTests NALUnitsTests MainMenuM3Tests KeyHandlingM3Tests OcclusionTests DisplayRangeMonitorTests VolumeWatcherTests PlayerModelM3Tests SettingsM3Tests"

# Sets TEST_LOG to the full swift test log of this run: check.sh's when it is newer than this
# run's start, else one run here. (Not a command substitution: the result is cached.)
TEST_LOG=""
ensure_test_log() {
  if [ -z "$TEST_LOG" ]; then
    local log="$REPO/build/check/test.log"
    if [ ! -f "$log" ] || [ ! -f "$RUN/ac01.start" ] || [ ! "$log" -nt "$RUN/ac01.start" ] || [ "${CHECK_RC:-1}" -ne 0 ]; then
      local home
      home="$(fresh_home)"
      REEL_HOME="$home" REEL_IINA_WATCH_LATER="" run_logged swift-test \
        caffeinate -i swift test --package-path "$REPO" --scratch-path "$SCRATCH" || true
      remove_run_path "$home"
      log="$RUN/swift-test.log"
    fi
    TEST_LOG="$log"
  fi
}

ac05() {
  local log suite problems="" n=0 summary
  ensure_test_log
  log="$TEST_LOG"
  if grep -q '^✘' "$log"; then
    problems="$problems [a test or suite failed]"
  fi
  for suite in $REQUIRED_SUITES $M2_SUITES $M3_SUITES; do
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
# M2 helpers
# ---------------------------------------------------------------------------------------------

M2_PROBLEMS=""
M2_LINES=""

# m2_step <label> <summary> <rc>: one sub-check of the criterion being built.
m2_step() {
  M2_LINES="$M2_LINES [$1: $2]"
  [ "$3" -eq 0 ] || M2_PROBLEMS="$M2_PROBLEMS [$1]"
  note "$1: $2"
}

# m2_eval <label> <json> <python code> [args...]: py_check on a report, recorded as one sub-check.
m2_eval() {
  local label=$1 json=$2 code=$3 out rc
  shift 3
  out="$(py_check "$json" "$code" "$@" 2>&1)"
  rc=$?
  m2_step "$label" "$out" $rc
}

# m2_finish <id> <what>: records PASS or FAIL for the sub-checks gathered since the last finish.
m2_finish() {
  if [ -n "$M2_PROBLEMS" ]; then
    fail "$1" "$2 not met:$M2_PROBLEMS;$M2_LINES"
  else
    pass "$1" "$M2_LINES"
  fi
  M2_PROBLEMS=""
  M2_LINES=""
}

# m2_suite <suite>: sub-check that the swift test log has the suite passing.
m2_suite() {
  ensure_test_log
  if grep -qE "^✔ Suite \"?$1\"? passed" "$TEST_LOG"; then
    m2_step "suite $1" passed 0
  else
    m2_step "suite $1" "not passing in $TEST_LOG" 1
  fi
}

# The result recorded for an id in this run: PASS, FAIL, SKIP or empty.
result_of() { awk -F'\t' -v id="$1" '$1 == id { status = $2 } END { print status }' "$RESULTS"; }

# ---------------------------------------------------------------------------------------------
# AC-M2-1
# ---------------------------------------------------------------------------------------------

ac_m2_1() {
  local plist="$APP/Contents/Info.plist" types="$RUN/document-types.json" usage
  run_check_once
  if [ "$CHECK_RC" -eq 0 ]; then
    m2_step "check.sh" "exits 0" 0
  else
    m2_step "check.sh" "failed, see $CHECK_LOG" 1
  fi
  if plutil -extract CFBundleDocumentTypes json -o "$types" "$plist" 2>"$RUN/document-types.err"; then
    m2_eval "document types" "$types" '
for ext in ("mkv", "webm", "mp4", "mov", "avi", "flv"):
    rows = [t for t in r if ext in [e.lower() for e in t.get("CFBundleTypeExtensions", [])]]
    ranks = [t.get("LSHandlerRank") for t in rows]
    parts.append("%s %s" % (ext, "/".join(str(x) for x in ranks) if ranks else "missing"))
    if not rows:
        problems.append(ext + " has no document type")
    elif any(x != "Default" for x in ranks):
        problems.append(ext + " rank is not Default")
'
  else
    m2_step "document types" "no CFBundleDocumentTypes in $plist" 1
  fi
  usage="$(plutil -extract NSDocumentsFolderUsageDescription raw -o - "$plist" 2>/dev/null || true)"
  if [ -n "$usage" ]; then
    m2_step "folder usage string" "present" 0
  else
    m2_step "folder usage string" "NSDocumentsFolderUsageDescription missing" 1
  fi
  m2_finish AC-M2-1 "gates and document types"
}

# ---------------------------------------------------------------------------------------------
# AC-M2-2
# ---------------------------------------------------------------------------------------------

ac_m2_2() {
  local F="$FIXTURES" suite
  if [ ! -f "$F/subs_tracks.mkv" ] || [ ! -f "$F/subs_pgs.mkv" ] || [ ! -f "$F/logs/pgs_rects.json" ]; then
    fail AC-M2-2 "subtitle fixtures missing in $F (run scripts/fixtures.sh)"
    return
  fi
  # (a) track choice
  run_ctl subs-select subs "$F/subs_tracks.mkv" --json || true
  m2_eval "(a) sidecar" "$RUN/subs-select.json" '
s = r.get("selected") or {}
parts.append("selected " + str(s.get("id")))
if s.get("id") != "external:subs_tracks.zh-Hans.srt" or not s.get("external"):
    problems.append("sidecar subs_tracks.zh-Hans.srt not selected")
'
  run_ctl subs-noext subs "$F/subs_tracks.mkv" --no-external --json || true
  m2_eval "(a) embedded" "$RUN/subs-noext.json" '
s = r.get("selected") or {}
parts.append("selected %s %s %s %s" % (s.get("id"), s.get("language"), s.get("format"), s.get("title")))
if s.get("external") or s.get("format") != "ASS" or s.get("language") != "zho" or s.get("title") != "简英双语":
    problems.append("not the embedded zho ASS titled 简英双语")
'
  # (b) rendering
  run_ctl subs-ink subs "$F/subs_tracks.mkv" --no-external --at 2.0 --size 1920x1080 --json || true
  m2_eval "(b) ink at 2.0" "$RUN/subs-ink.json" '
ink = r.get("ink_pixels")
missing = r.get("missing_glyphs")
fonts = r.get("fonts") or []
box = r.get("bbox")
parts.append("ink %s, missing glyphs %s, fonts %s" % (ink, missing, ",".join(fonts) or "none"))
if ink is None or ink < 3000:
    problems.append("ink under 3000")
if missing != 0:
    problems.append("missing glyphs")
# Design 8.4: PingFang when FreeType can read it (Reel rebuilds it from CoreText paths), else the
# documented fallback Hiragino Sans GB (macOS 27 ships PingFang only as hvgl outlines).
def cjk_face(name):
    key = name.lower().replace(" ", "").replace("-", "")
    return key.startswith("pingfang") or key.startswith("hiraginosansgb")
cjk = [f for f in fonts if cjk_face(f)]
if not cjk:
    problems.append("no CJK face from the fallback list, PingFang or Hiragino Sans GB (substitutions: %s)" % r.get("font_substitutions"))
else:
    parts.append("CJK face " + cjk[0])
if box:
    centre = box["x"] + box["w"] / 2.0
    bottom = box["y"] + box["h"]
    parts.append("bbox centre x %.0f, bottom %d" % (centre, bottom))
    if abs(centre - 960) > 960 * 0.02:
        problems.append("centre x not within 2 percent of 960")
    if not 918 <= bottom <= 1048:
        problems.append("bottom outside 918 to 1048")
else:
    problems.append("no bbox")
'
  run_ctl subs-quiet subs "$F/subs_tracks.mkv" --no-external --at 0.5 --size 1920x1080 --json || true
  m2_eval "(b) nothing at 0.5" "$RUN/subs-quiet.json" '
ink = r.get("ink_pixels")
parts.append("ink %s" % ink)
if ink != 0:
    problems.append("ink at 0.5 is not 0")
'
  # (c) charset
  run_ctl subs-utf8 subs "$F/subs_utf8.srt" --dump-text --json || true
  run_ctl subs-gbk subs "$F/subs_gbk.srt" --dump-text --json || true
  run_ctl subs-big5 subs "$F/subs_big5.cht.srt" --dump-text --json || true
  local pair name want
  for pair in "gbk GB18030" "big5 BIG5"; do
    # shellcheck disable=SC2086
    set -- $pair
    name=$1 want=$2
    m2_eval "(c) $name" "$RUN/subs-$name.json" '
want = sys.argv[3]
ref = json.load(open(sys.argv[4]))
parts.append("charset %s, %d characters" % (r.get("charset"), len(r.get("text") or "")))
if r.get("charset") != want:
    problems.append("charset is not " + want)
if not r.get("text") or r.get("text") != ref.get("text"):
    problems.append("text differs from subs_utf8.srt")
' "$want" "$RUN/subs-utf8.json"
  done
  # (d) PGS
  run_ctl subs-pgs subs "$F/subs_pgs.mkv" --at 2.0 --size 1920x1080 --json || true
  m2_eval "(d) PGS rectangle" "$RUN/subs-pgs.json" '
rect = json.load(open(sys.argv[3]))["rects"][0]
box = r.get("bbox") or {}
names = {"x": "x", "y": "y", "w": "width", "h": "height"}
parts.append("bbox %s vs rect %s" % (box, {k: rect[v] for k, v in names.items()}))
if not box:
    problems.append("no bbox")
for key, source in names.items():
    if abs(box.get(key, -9999) - rect[source]) > 2:
        problems.append(key + " off by more than 2 px")
' "$F/logs/pgs_rects.json"
  run_ctl subs-pgs-quiet subs "$F/subs_pgs.mkv" --at 3.5 --size 1920x1080 --json || true
  m2_eval "(d) PGS gap" "$RUN/subs-pgs-quiet.json" '
ink = r.get("ink_pixels")
parts.append("ink %s" % ink)
if ink != 0:
    problems.append("ink at 3.5 is not 0")
'
  # (e) steady-state render time
  run_ctl subs-frames subs "$F/subs_tracks.mkv" --no-external --at 2.0 --size 1920x1080 --frames 100 --json || true
  m2_eval "(e) render p95" "$RUN/subs-frames.json" '
t = r.get("render_ms") or {}
parts.append("render_ms p95 %s ms over %s frames" % (t.get("p95"), t.get("frames")))
if t.get("p95") is None or t["p95"] > 16:
    problems.append("p95 over 16 ms")
if (t.get("frames") or 0) < 100:
    problems.append("fewer than 100 frames")
'
  # (f) suites
  for suite in SubtitleRenderTests SubtitleCharsetDecodeTests BitmapSubtitleTests; do
    m2_suite "$suite"
  done
  m2_finish AC-M2-2 "subtitle checks"
}

# ---------------------------------------------------------------------------------------------
# AC-M2-3
# ---------------------------------------------------------------------------------------------

ac_m2_3() {
  local spec name budget file
  for spec in "hevc10_1080p24.mkv 15" "h264_1080p30.mp4 15" "av1_2160p60.mkv 40" "vp9_2160p60.webm 60"; do
    # shellcheck disable=SC2086
    set -- $spec
    name=$1 budget=$2
    file="$FIXTURES/$name"
    if [ ! -f "$file" ]; then
      m2_step "$name" "fixture missing" 1
      continue
    fi
    cat "$file" >/dev/null # warm the file cache; the media is our own fixture
    run_ctl "thumbs-$name" thumbs "$file" --runs 3 --fresh-cache --json || true
    m2_eval "$name" "$RUN/thumbs-$name.json" '
budget = float(sys.argv[3])
per = r.get("per_thumb_ms") or {}
amortised = (per.get("amortised") or {}).get("p95")
latency = (per.get("latency") or {}).get("max")
setup = r.get("setup_ms")
count = r.get("count")
total = r.get("keyframes_total")
widths = r.get("image_widths") or []
luma = r.get("min_luma_stddev")
reload = r.get("cache_reload_ms")
parts.append("amortised p95 %s/%g ms, max latency %s/%g ms, setup %s/150 ms, count %s of %s keyframes, widths %s, min luma stddev %s/8, reload %s/50 ms" % (
    amortised, budget, latency, 3 * budget, setup, count, total, sorted(set(widths)), luma, reload))
if amortised is None or amortised > budget:
    problems.append("amortised p95 over budget")
if latency is None or latency > 3 * budget:
    problems.append("max latency over 3 times budget")
if setup is None or setup > 150:
    problems.append("setup over 150 ms")
if total is None or count != min(total, 400):
    problems.append("count is not min(keyframes_total, 400)")
if not widths or any(w != 384 for w in widths):
    problems.append("an image is not 384 px wide")
if luma is None or luma < 8:
    problems.append("an image is nearly blank")
if reload is None or reload > 50:
    problems.append("cache reload over 50 ms")
if r.get("failures"):
    problems.append("failures: " + "; ".join(r["failures"]))
' "$budget"
  done
  local hevc="$FIXTURES/hevc10_1080p24.mkv" out rc
  if [ -f "$hevc" ]; then
    cat "$hevc" >/dev/null
    run_ctl seek-thumbs-hevc seek-bench "$hevc" --runs 20 --with-thumbs --json || true
    out="$(eval_seek "$RUN/seek-thumbs-hevc.json" 200 50 250 2>&1)"
    rc=$?
    m2_step "HEVC seek with thumbnails" "$out" $rc
  else
    m2_step "HEVC seek with thumbnails" "fixture missing" 1
  fi
  m2_finish AC-M2-3 "thumbnail budgets"
}

# ---------------------------------------------------------------------------------------------
# AC-M2-4
# ---------------------------------------------------------------------------------------------

M2_EPISODE_TESTS="naturalSortOrdersEpisodeNumbers nextAfterLastIsNil opensNextAfterCountdown cancelStopsAutoAdvance hoverPausesCountdown fileLoopDisablesAutoAdvance trackChoiceCarriesToNextEpisode"

ac_m2_4() {
  local home test log n=0 missing=""
  # Relative to the repo when the fixtures are inside it: reelctl resolves it against the working
  # directory, whose letter case is the real one. EpisodeList.scan compares URLs, so a path
  # spelled with a different case than the folder's finds no neighbours (reported, not hidden).
  local episode="$FIXTURES/episodes/Northern.Line.S01E02.mkv"
  case "$episode" in
    "$REPO"/*) episode="${episode#"$REPO"/}" ;;
  esac
  run_ctl episodes episodes "$episode" --json || true
  m2_eval "episode order" "$RUN/episodes.json" '
want = ["Northern.Line.S01E01.mkv", "Northern.Line.S01E02.mkv", "Northern.Line.S01E03.mkv", "Northern.Line.S01E10.mkv"]
parts.append("%s, next %s, previous %s" % (r.get("episodes"), r.get("next"), r.get("previous")))
if r.get("episodes") != want:
    problems.append("episodes are not exactly the four, in order")
if r.get("next") != "Northern.Line.S01E03.mkv":
    problems.append("next is not S01E03")
if r.get("previous") != "Northern.Line.S01E01.mkv":
    problems.append("previous is not S01E01")
'
  home="$(fresh_home)"
  REEL_HOME="$home" REEL_IINA_WATCH_LATER="" run_logged episode-tests \
    caffeinate -i swift test --package-path "$REPO" --scratch-path "$SCRATCH" --filter "EpisodeListTests|AutoAdvanceTests" || true
  remove_run_path "$home"
  log="$LAST_LOG"
  for test in $M2_EPISODE_TESTS; do
    if grep -qE "^✔ Test \"?$test(\\(\\))?\"? passed" "$log"; then
      n=$((n + 1))
    else
      missing="$missing $test"
    fi
  done
  if grep -q '^✘' "$log"; then missing="$missing [a test failed]"; fi
  if [ -z "$missing" ]; then
    m2_step "EpisodeListTests and AutoAdvanceTests" "$n named tests passed" 0
  else
    m2_step "EpisodeListTests and AutoAdvanceTests" "not passing:$missing (see $log)" 1
  fi
  m2_finish AC-M2-4 "episode order and auto-advance"
}

# ---------------------------------------------------------------------------------------------
# AC-M2-5
# ---------------------------------------------------------------------------------------------

# scripts/shots.sh runs once per accept run with all 28 scenarios; AC-M2-5 reads its 15 scenarios
# by name and AC-M3-6 the 8 new ones. The log is copied because the next shots.sh run rewrites it.
SHOTS_RC=""
SHOTS_BEFORE=""
SHOTS_AFTER=""
run_shots_once() {
  [ -z "$SHOTS_RC" ] || return 0
  if [ ! -x "$APP/Contents/MacOS/Reel" ]; then
    run_logged bundle "$REPO/scripts/bundle.sh" --release || true
  fi
  SHOTS_BEFORE="$(front)"
  run_logged all-shots "$REPO/scripts/shots.sh"
  SHOTS_RC=$?
  SHOTS_AFTER="$(front)"
  cp "$REPO/build/shots/shots.log" "$RUN/shots-all.log" 2>/dev/null || : >"$RUN/shots-all.log"
}

M2_SCENARIOS="empty playing paused-osd scrubbing subtitle-panel audio-panel speed-panel thumbnail subtitles subtitles-lifted osd-speed osd-loop next-episode fullscreen edge-states"
# Pixel rectangles (2x, 1280x720 points) just inside the controller: the default position,
# the subtitles scenario (controller near the top) and fullscreen (56 pt from the bottom).
SUBTITLES_CTRL_RECT="800 108 960 144"
FULLSCREEN_CTRL_RECT="774 1176 960 144"
# Bottom 25% of the image, and the band of 330 px above the default controller (1121 px).
BOTTOM_QUARTER="0 1080 2560 360"
LIFTED_BAND="0 790 2560 330"

m2_region() {
  case "$1" in
    subtitles) echo "$SUBTITLES_CTRL_RECT" ;;
    fullscreen) echo "$FULLSCREEN_CTRL_RECT" ;;
    *) echo "$CTRL_RECT" ;;
  esac
}

ac_m2_5() {
  local before after rc=0 problems="" scn mode f stats width height low high light dark diff count=0 ink log lines bad
  run_shots_once
  before="$SHOTS_BEFORE"
  rc=$SHOTS_RC
  after="$SHOTS_AFTER"
  note "lsappinfo front before: $before"
  note "lsappinfo front after: $after"
  if [ $rc -ne 0 ]; then
    case $rc in
      3) problems="$problems [frontmost app changed]" ;;
      4) problems="$problems [an on-screen window appeared]" ;;
      5) problems="$problems [a shot process registered as an application]" ;;
      *) problems="$problems [shots.sh exit $rc, see $RUN/all-shots.log]" ;;
    esac
  fi
  if [ "$before" != "$after" ]; then
    problems="$problems [lsappinfo front changed: $before -> $after]"
  fi
  for scn in $M2_SCENARIOS; do
    for mode in light dark; do
      f="$REPO/build/shots/$scn-$mode.png"
      if [ ! -s "$f" ]; then
        problems="$problems [missing $scn-$mode.png]"
        continue
      fi
      stats="$("$TOOLS/shot-stats" "$f" 2>/dev/null || true)"
      width="$(echo "$stats" | awk '{print $1}')"
      height="$(echo "$stats" | awk '{print $2}')"
      low="$(echo "$stats" | awk '{print $5}')"
      high="$(echo "$stats" | awk '{print $6}')"
      if [ "$width" != 2560 ] || [ "$height" != 1440 ]; then
        problems="$problems [$scn-$mode is ${width:-?}x${height:-?}]"
      elif ! awk -v lo="${low:-0}" -v hi="${high:-0}" 'BEGIN { exit !(hi - lo >= 16) }'; then
        problems="$problems [$scn-$mode is blank, luminance $low to $high]"
      else
        count=$((count + 1))
      fi
    done
  done
  # The empty window has no controller or panel; every other scenario has one of them.
  for scn in $M2_SCENARIOS; do
    [ "$scn" != empty ] || continue
    # shellcheck disable=SC2046
    light="$("$TOOLS/shot-stats" "$REPO/build/shots/$scn-light.png" $(m2_region "$scn") 2>/dev/null | awk '{print $3}')"
    # shellcheck disable=SC2046
    dark="$("$TOOLS/shot-stats" "$REPO/build/shots/$scn-dark.png" $(m2_region "$scn") 2>/dev/null | awk '{print $3}')"
    if [ -z "$light" ] || [ -z "$dark" ]; then
      problems="$problems [no controller stats for $scn]"
      continue
    fi
    diff="$(awk -v a="$light" -v b="$dark" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.1f", d }')"
    note "$scn controller luminance light $light dark $dark diff $diff"
    if ! awk -v d="$diff" 'BEGIN { exit !(d >= 20) }'; then
      problems="$problems [$scn controller light/dark differ by only $diff/255]"
    fi
  done
  for mode in light dark; do
    # shellcheck disable=SC2086
    ink="$("$TOOLS/shot-stats" "$REPO/build/shots/subtitles-$mode.png" --ink $BOTTOM_QUARTER 2>/dev/null || echo 0)"
    note "subtitles-$mode outlined ink in the bottom quarter: $ink"
    [ "${ink:-0}" -ge 1500 ] || problems="$problems [subtitles-$mode has $ink outlined white pixels in the bottom quarter]"
    # shellcheck disable=SC2086
    ink="$("$TOOLS/shot-stats" "$REPO/build/shots/subtitles-lifted-$mode.png" --ink $LIFTED_BAND 2>/dev/null || echo 0)"
    note "subtitles-lifted-$mode outlined ink above the controller: $ink"
    [ "${ink:-0}" -ge 1500 ] || problems="$problems [subtitles-lifted-$mode has $ink outlined white pixels above the controller]"
  done
  # Every launch recorded the frontmost app before and after; they must match.
  log="$RUN/shots-all.log"
  lines="$(grep -E "^($(echo "$M2_SCENARIOS" | tr ' ' '|')) (light|dark) pid=" "$log" 2>/dev/null | sed -n 's/.* before=\[\(.*\)\] after=\[\(.*\)\]$/\1|\2/p' || true)"
  n_launches="$(echo "$lines" | grep -c . || true)"
  bad="$(echo "$lines" | awk -F'|' 'NF && $1 != $2' | wc -l | tr -d ' ')"
  note "shots.log: $n_launches launches, $bad with a changed frontmost app"
  [ "$n_launches" -eq 32 ] || problems="$problems [shots.log has $n_launches launches of the M2 scenarios, expected 32]"
  [ "$bad" -eq 0 ] || problems="$problems [shots.log shows $bad launches that changed the frontmost app]"
  # The ink counts prove libass output only if libass drew it: shot mode has no sample-line
  # fallback any more, and each of the four subtitle shots logs its libass rectangle.
  local registered drawn fallback
  registered="$(grep -c ' app=\[[^n]' "$log" 2>/dev/null || true)"
  drawn="$(grep -c 'subtitle drawn by libass' "$log" 2>/dev/null || true)"
  fallback="$(grep -cE 'sample subtitle lines|subtitle render failed|needs libass output' "$log" 2>/dev/null || true)"
  note "shots.log: ${registered:-0} launches registered as an application, ${drawn:-0} libass subtitle renders, ${fallback:-0} fallbacks"
  [ "${registered:-0}" -eq 0 ] || problems="$problems [shots.log shows $registered launches registered as an application]"
  [ "${drawn:-0}" -eq 4 ] || problems="$problems [shots.log shows ${drawn:-0} libass subtitle renders, expected 4]"
  [ "${fallback:-0}" -eq 0 ] || problems="$problems [shots.log shows a subtitle fallback]"
  if [ -n "$problems" ]; then
    fail AC-M2-5 "screenshots:$problems"
  else
    pass AC-M2-5 "$count PNGs at 2560x1440, not blank, controller light/dark differ, outlined subtitle ink, $n_launches launches with before == after, front unchanged ($after), no window"
  fi
}

# ---------------------------------------------------------------------------------------------
# AC-M2-6
# ---------------------------------------------------------------------------------------------

ac_m2_6() {
  local file="$FIXTURES/vp9_2160p60.webm" status
  if [ ! -f "$file" ]; then
    fail AC-M2-6 "vp9_2160p60.webm missing in $FIXTURES"
    return
  fi
  # AC02 ran this exact command; run it here only when that criterion did not.
  if [ ! -s "$RUN/seek-vp9.json" ]; then
    cat "$file" >/dev/null
    run_ctl seek-vp9 seek-bench "$file" --json --runs 20 || true
  fi
  m2_eval "VP9 hybrid seeks" "$RUN/seek-vp9.json" '
exact = (r.get("exactWorst") or {}).get("p95")
key = (r.get("keyframeSeek") or {}).get("p95")
checked = r.get("exactChecked", 0)
landed = r.get("exactLandedCorrect", 0)
psnr = r.get("psnr") or []
decibels = [s.get("decibels") for s in psnr]
handoffs = r.get("decoder_handoffs", 0)
known = [d for d in decibels if d is not None]
parts.append("exact worst p95 %s/800 ms, keyframe p95 %s/100 ms, landed %d/%d, psnr min %s dB over %d, hand-offs %s" % (
    exact, key, landed, checked, "none" if not known else "%.1f" % min(known), len(psnr), handoffs))
if exact is None or exact > 800:
    problems.append("exact worst-case p95 over 800 ms")
if key is None or key > 100:
    problems.append("keyframe p95 over 100 ms")
if checked == 0 or landed != checked:
    problems.append("exact seeks landed on the wrong frame")
if not psnr or len(known) != len(decibels) or min(known) < 35:
    problems.append("psnr below 35 dB or missing")
if handoffs < 1:
    problems.append("no decoder hand-off")
if r.get("misses"):
    problems.append("%d misses" % len(r["misses"]))
'
  for id in AC02 AC03; do
    status="$(result_of "$id")"
    if [ -z "$status" ]; then
      # Standalone m2 run: M1's criteria have not run yet in this folder.
      if [ "$id" = AC02 ]; then ac02 >/dev/null; else ac03 >/dev/null; fi
      status="$(result_of "$id")"
    fi
    if [ "$status" = PASS ]; then
      m2_step "M1 $id" "still passes" 0
    else
      m2_step "M1 $id" "is ${status:-missing}" 1
    fi
  done
  m2_finish AC-M2-6 "VP9 hybrid decode"
}

group_m2() {
  echo
  echo "== m2"
  ac_m2_1
  if [ -x "${CTL:-}" ]; then
    ac_m2_2
    ac_m2_3
    ac_m2_4
  else
    fail AC-M2-2 "no reelctl"
    fail AC-M2-3 "no reelctl"
    fail AC-M2-4 "no reelctl"
  fi
  ac_m2_5
  if [ -x "${CTL:-}" ]; then
    ac_m2_6
  else
    fail AC-M2-6 "no reelctl"
  fi
}

# ---------------------------------------------------------------------------------------------
# M3 helpers
# ---------------------------------------------------------------------------------------------

# m3_test <suite> <test>: sub-check that a named test passed in the swift test log.
m3_test() {
  ensure_test_log
  if grep -qE "^✔ Test \"?$2(\\(\\))?\"? passed" "$TEST_LOG"; then
    m2_step "$1.$2" passed 0
  else
    m2_step "$1.$2" "not passing in $TEST_LOG" 1
  fi
}

# Everything that follows the M1 and M2 groups in the same run counts as "prior".
M1_M2_IDS="AC01 AC02 AC03 AC04 AC05 AC-M2-1 AC-M2-2 AC-M2-3 AC-M2-4 AC-M2-5 AC-M2-6"

# ---------------------------------------------------------------------------------------------
# AC-M3-1
# ---------------------------------------------------------------------------------------------

ac_m3_1() {
  local line gate id status missing="" bad="" n=0
  run_check_once
  if [ "$CHECK_RC" -eq 0 ]; then
    m2_step "check.sh" "exits 0" 0
  else
    m2_step "check.sh" "failed, see $CHECK_LOG" 1
  fi
  for gate in av-sync soak-smoke; do
    line="$(grep -E "^$gate +(ok|FAIL)" "$CHECK_LOG" 2>/dev/null | head -1 || true)"
    case "$line" in
      "$gate"*" ok "*) m2_step "gate $gate" "$line" 0 ;;
      "") m2_step "gate $gate" "not in the check.sh output" 1 ;;
      *) m2_step "gate $gate" "$line" 1 ;;
    esac
  done
  for id in $M1_M2_IDS; do
    status="$(result_of "$id")"
    case "$status" in
      PASS) n=$((n + 1)) ;;
      "") missing="$missing $id" ;;
      *) bad="$bad $id=$status" ;;
    esac
  done
  if [ -n "$bad" ]; then
    m2_step "M1 and M2 criteria" "not passing:$bad" 1
  elif [ -n "$missing" ] && [ "$GROUP" = offline ]; then
    m2_step "M1 and M2 criteria" "no result for:$missing" 1
  elif [ -n "$missing" ]; then
    m2_step "M1 and M2 criteria" "$n pass; not run in this group (scripts/accept.sh offline runs them):$missing" 0
  else
    m2_step "M1 and M2 criteria" "all $n PASS" 0
  fi
  m2_finish AC-M3-1 "gates and regressions"
}

# ---------------------------------------------------------------------------------------------
# AC-M3-2
# ---------------------------------------------------------------------------------------------

# The checks on one `reelctl hdr` report of a ramp file: <kind> <code tolerance> <file name>.
HDR_RAMP_CODE='
want_kind, tolerance, name = sys.argv[3], int(sys.argv[4]), sys.argv[5]
hlg = want_kind == "hlg"
transfer = "ITU_R_2100_HLG" if hlg else "SMPTE_ST_2084_PQ"
parts.append("kind %s" % r.get("kind"))
if r.get("kind") != want_kind:
    problems.append("kind is not " + want_kind)
worst = 0
for p in r.get("patches") or []:
    d, e = p.get("decoded"), p.get("expected")
    if not d:
        problems.append("no decoded codes for " + p.get("name", "?"))
        continue
    for k in ("y", "cb", "cr"):
        worst = max(worst, abs(d[k] - e[k]))
parts.append("code error %d/%d" % (worst, tolerance))
if worst > tolerance:
    problems.append("decoded codes off by more than %d" % tolerance)
a = r.get("attachments") or {}
parts.append("%s %s %s" % (a.get("primaries"), a.get("matrix"), a.get("transfer")))
if a.get("primaries") != "ITU_R_2020" or a.get("matrix") != "ITU_R_2020" or a.get("transfer") != transfer:
    problems.append("attachments are not BT.2020 / BT.2020 / " + transfer)
if not hlg:
    m, c = a.get("masteringDisplay") or {}, a.get("contentLightLevel") or {}
    parts.append("MDCV max %s nits, CLL %s/%s" % (m.get("maxLuminance"), c.get("maxCLL"), c.get("maxFALL")))
    if abs((m.get("maxLuminance") or 0) - 1000) > 0.5:
        problems.append("MDCV max luminance is not 1000 nits")
    if c.get("maxCLL") != 1000 or c.get("maxFALL") != 400:
        problems.append("CLL is not 1000 and 400")

def neutral(label, n):
    lumas = n.get("lumas") or []
    ok = True
    for i in range(len(lumas) - 1):
        if lumas[i] >= 255:
            break
        if not lumas[i] < lumas[i + 1]:
            ok = False
    need = 5 if hlg else 7
    distinct = len(set(lumas))
    white = n.get("referenceWhiteValue")
    parts.append("%s lumas %s, white %s, spread %s" % (label, lumas, white, n.get("maxNeutralSpread")))
    if not ok:
        problems.append(label + " not strictly increasing up to the clip")
    if distinct < need:
        problems.append("%s has %d distinct values, need %d" % (label, distinct, need))
    if not lumas or lumas[0] > 3:
        problems.append(label + " black patch over 3")
    if white is None or not 190 <= white <= 250:
        problems.append(label + " reference white outside 190 to 250")
    if n.get("maxNeutralSpread") is None or n["maxNeutralSpread"] > 3:
        problems.append(label + " neutral patch channels differ by more than 3")

neutral("HDRToneMapper", r.get("toneMapped") or {})
shot = r.get("screenshot") or {}
if not shot.get("neutral"):
    problems.append("no screenshot readback")
else:
    neutral("screenshot", shot["neutral"])
    if not shot.get("iccProfile"):
        problems.append("screenshot has no ICC profile")
t = r.get("thumbnail") or {}
parts.append("thumbnail white %s" % t.get("luma"))
if t.get("luma") is None or not 185 <= t["luma"] <= 250:
    problems.append("thumbnail reference white outside 185 to 250")
'

ac_m3_2() {
  local F="$FIXTURES/hdr" spec file kind tol decoder tag suite display setting layer
  if [ ! -f "$F/pq_ramp_hevc.mkv" ]; then
    fail AC-M3-2 "hdr fixtures missing in $F (run scripts/fixtures.sh)"
    return
  fi
  for spec in "pq_ramp_hevc.mkv hdr10 2" "pq_ramp_hevc.mp4 hdr10 2" "hlg_ramp_hevc.mkv hlg 2" \
    "hlg_ramp_hevc.mp4 hlg 2" "pq_ramp_av1.mkv hdr10 4" "pq_ramp_vp9.webm hdr10 4"; do
    # shellcheck disable=SC2086
    set -- $spec
    file=$1 kind=$2 tol=$3
    for decoder in hw sw; do
      tag="hdr-$file-$decoder"
      run_ctl "$tag" hdr "$F/$file" --decoder $decoder --screenshot "$RUN/$tag.png" --thumbnail --json || true
      m2_eval "$file $decoder" "$RUN/$tag.json" "$HDR_RAMP_CODE" "$kind" "$tol" "$file"
    done
  done
  run_ctl hdr-sdr-control hdr "$F/sdr_ramp_h264.mp4" --json || true
  m2_eval "sdr_ramp_h264.mp4" "$RUN/hdr-sdr-control.json" '
p = r.get("plan") or {}
parts.append("kind %s, layer %s, tag %s" % (r.get("kind"), p.get("layer"), p.get("tag")))
if r.get("kind") != "sdr":
    problems.append("kind is not sdr")
if p.get("layer") != "standard":
    problems.append("layer is not standard")
if p.get("tag"):
    problems.append("an SDR file has a tag")
'
  for display in sdr xdr external; do
    for setting in full limited off; do
      tag="plan-$display-$setting"
      run_ctl "$tag" hdr "$F/pq_ramp_hevc.mkv" --display $display --setting $setting --json || true
      m2_eval "plan $display $setting" "$RUN/$tag.json" '
display, setting = sys.argv[3], sys.argv[4]
p = r.get("plan") or {}
layer = {"full": "high", "limited": "constrainedHigh", "off": "standard"}[setting]
detail = p.get("tagDetail")
want_detail = "SDR" if display == "sdr" or setting == "off" else None
parts.append("layer %s, overlay %s, tag %s, detail %s" % (p.get("layer"), p.get("overlay"), p.get("tag"), detail))
if p.get("layer") != layer:
    problems.append("layer is not " + layer)
if p.get("overlay") != "standard":
    problems.append("overlay is not standard")
if p.get("tag") != "HDR10":
    problems.append("tag is not HDR10")
if detail != want_detail:
    problems.append("tagDetail is %s, expected %s" % (detail, want_detail))
' "$display" "$setting"
    done
  done
  for suite in HDRDecodeTests HDRToneMapTests DynamicRangePlanTests DynamicRangeLayerTests; do
    m2_suite "$suite"
  done
  m2_finish AC-M3-2 "HDR10 and HLG numbers"
}

# ---------------------------------------------------------------------------------------------
# AC-M3-3
# ---------------------------------------------------------------------------------------------

ac_m3_3() {
  local F="$FIXTURES/hdr" spec file profile compat decoder tag suite
  if [ ! -f "$F/dv81.mp4" ]; then
    fail AC-M3-3 "Dolby Vision fixtures missing in $F (run scripts/fixtures.sh)"
    return
  fi
  for spec in "dv81.mp4 8 1" "dv81.mkv 8 1" "dv84.mp4 8 4" "dv5.mp4 5 0" "pq_ramp_hevc.mp4 none none"; do
    # shellcheck disable=SC2086
    set -- $spec
    file=$1 profile=$2 compat=$3
    run_ctl "probe-$file" probe "$F/$file" --json || true
    m2_eval "probe $file" "$RUN/probe-$file.json" '
profile, compat = sys.argv[3], sys.argv[4]
dv = r.get("dolbyVision")
parts.append("dolbyVision %s" % ("none" if not dv else "profile %s compatibility %s" % (dv.get("profile"), dv.get("compatibilityID"))))
if profile == "none":
    if dv:
        problems.append("an HDR10 file reports Dolby Vision")
elif not dv or dv.get("profile") != int(profile) or dv.get("compatibilityID") != int(compat):
    problems.append("expected profile %s compatibility %s" % (profile, compat))
' "$profile" "$compat"
  done
  run_ctl hdr3-pq-reference hdr "$F/pq_ramp_hevc.mp4" --decoder hw --json || true
  for decoder in hw sw; do
    tag="hdr3-dv81-$decoder"
    run_ctl "$tag" hdr "$F/dv81.mp4" --decoder $decoder --json || true
    m2_eval "dv81.mp4 $decoder" "$RUN/$tag.json" '
ref = json.load(open(sys.argv[3]))
want = {p["name"]: p["expected"] for p in ref.get("patches") or []}
worst = 0
seen = 0
for p in r.get("patches") or []:
    d = p.get("decoded")
    e = want.get(p.get("name"))
    if not d or not e:
        problems.append("patch %s has no decoded codes or no reference" % p.get("name"))
        continue
    seen += 1
    for k in ("y", "cb", "cr"):
        worst = max(worst, abs(d[k] - e[k]))
plan = r.get("plan") or {}
parts.append("%d patches, code error %d/2 against pq_ramp_hevc.mp4, layer %s, tag %s, note %s" % (
    seen, worst, plan.get("layer"), plan.get("tag"), plan.get("note")))
if seen == 0 or worst > 2:
    problems.append("decoded codes differ from the PQ ramp by more than 2")
if plan.get("layer") != "high":
    problems.append("layer is not high")
if plan.get("tag") != "Dolby Vision":
    problems.append("tag is not Dolby Vision")
if plan.get("note") is not False:
    problems.append("note is not false")
' "$RUN/hdr3-pq-reference.json"
  done
  run_ctl hdr3-dv84 hdr "$F/dv84.mp4" --json || true
  m2_eval "dv84.mp4" "$RUN/hdr3-dv84.json" '
dv = r.get("dolbyVision") or {}
a = r.get("attachments") or {}
parts.append("kind %s, base %s, transfer %s, primaries %s" % (r.get("kind"), dv.get("base"), a.get("transfer"), a.get("primaries")))
if r.get("kind") != "dolbyVision" or dv.get("base") != "hlg":
    problems.append("not Dolby Vision with an HLG base")
if a.get("transfer") != "ITU_R_2100_HLG" or a.get("primaries") != "ITU_R_2020" or a.get("matrix") != "ITU_R_2020":
    problems.append("attachments are not HLG BT.2020")
'
  run_ctl hdr3-dv5 hdr "$F/dv5.mp4" --json || true
  m2_eval "dv5.mp4" "$RUN/hdr3-dv5.json" '
plan = r.get("plan") or {}
dv = r.get("dolbyVision") or {}
parts.append("note %s, tag %s, warning %s" % (plan.get("note"), plan.get("tag"), plan.get("warning")))
if plan.get("note") is not True:
    problems.append("note is not true")
if plan.get("tag") != "Dolby Vision 5":
    problems.append("tag is not Dolby Vision 5")
if plan.get("warning") is not True or dv.get("warning") is not True:
    problems.append("warning flag is not set")
'
  for suite in DolbyVisionPolicyTests DolbyVisionProbeTests; do
    m2_suite "$suite"
  done
  m3_test NALUnitsTests dolbyVisionRPUAndEnhancementLayerUnitsAreNeverSkippable
  m2_finish AC-M3-3 "Dolby Vision handling"
}

# ---------------------------------------------------------------------------------------------
# AC-M3-4
# ---------------------------------------------------------------------------------------------

# Budgets from design 7.9: play, paused and occluded, CPU percent of one core, wakeups per second.
# The doc's rule (a budget the M2 baseline beats by more than 3 times becomes 2 times the
# baseline) is applied by editing these numbers; section 16 says which, if any, changed.
BUDGET_HEVC_PLAY="4 150"
BUDGET_AV1_PLAY="10 300"
BUDGET_PAUSED="0.3 5"
BUDGET_OCCLUDED="2 60"

# m3_energy <fixture> <mode> <cpu max> <wakeups max> <frames expected>
m3_energy() {
  local file=$1 mode=$2 cpu=$3 wakeups=$4 frames=$5 tag="energy-$2-$1"
  if [ ! -f "$FIXTURES/$file" ]; then
    m2_step "$mode $file" "fixture missing" 1
    return
  fi
  run_ctl "$tag" energy-bench "$FIXTURES/$file" --mode "$mode" --seconds 20 --warmup 5 --json || true
  m2_eval "$mode $file" "$RUN/$tag.json" '
mode, cpu_max, wake_max, frames = sys.argv[3], float(sys.argv[4]), float(sys.argv[5]), int(sys.argv[6])
c = r.get("counters") or {}
cpu, wake = r.get("cpuPercent"), r.get("wakeupsPerSecond")
parts.append("cpu %.2f/%g %%, wakeups %.1f/%g per s, decoded %s, packets %s, subtitle renders %s, time events %s" % (
    cpu or -1, cpu_max, wake or -1, wake_max, c.get("framesDecoded"), c.get("packetsRead"), c.get("subtitleRenders"), c.get("timeEvents")))
if r.get("audioRenderer") is not False:
    problems.append("an audio renderer was attached")
if cpu is None or cpu > cpu_max:
    problems.append("cpu over %g%%" % cpu_max)
if wake is None or wake > wake_max:
    problems.append("wakeups over %g per second" % wake_max)
if mode == "play":
    if abs((c.get("framesDecoded") or 0) - frames) > 0.02 * frames:
        problems.append("frames decoded not within 2%% of %d" % frames)
elif mode == "paused":
    for key in ("framesDecoded", "packetsRead", "subtitleRenders", "timeEvents"):
        if c.get(key) != 0:
            problems.append("%s is %s while paused" % (key, c.get(key)))
else:
    after = r.get("framesDecodedAfterFirstSecond")
    resync = r.get("resyncMs")
    parts.append("decoded after the first second %s, resync %s ms, sink %s" % (after, resync, r.get("sink")))
    if after != 0:
        problems.append("video frames decoded after the first second of occlusion")
    if resync is None or resync > 300:
        problems.append("resync over 300 ms")
' "$mode" "$cpu" "$wakeups" "$frames"
}

ac_m3_4() {
  # shellcheck disable=SC2086
  {
    m3_energy hevc10_1080p24.mkv play $BUDGET_HEVC_PLAY 480
    m3_energy av1_2160p60.mkv play $BUDGET_AV1_PLAY 1200
    m3_energy hevc10_1080p24.mkv paused $BUDGET_PAUSED 0
    m3_energy av1_2160p60.mkv paused $BUDGET_PAUSED 0
    m3_energy hevc10_1080p24.mkv occluded $BUDGET_OCCLUDED 0
  }
  m2_suite EnergyTests
  m2_finish AC-M3-4 "energy budgets"
}

# ---------------------------------------------------------------------------------------------
# AC-M3-5
# ---------------------------------------------------------------------------------------------

# Checks on one soak report: <corpus|odd> <manifest path or none>.
SOAK_CHECK='
which, manifest_path = sys.argv[3], sys.argv[4]
t = r.get("totals") or {}
files = r.get("files") or []
parts.append("%s: %d files, crashes %s, hangs %s, leaks %s, mismatches %s, played %s, classified %s, damaged frames %s, longest operation %.0f ms" % (
    which, t.get("files", 0), t.get("crashes"), t.get("hangs"), t.get("leaks"), t.get("mismatches"),
    t.get("played"), t.get("classified"), t.get("damagedFrames"), t.get("longestOperationMs", 0)))
if not files:
    problems.append("no files in the report")
for key in ("crashes", "hangs", "leaks", "mismatches"):
    if t.get(key) != 0:
        problems.append("%s %s" % (key, t.get(key)))
for f in files:
    name = f["file"].rsplit("/", 1)[-1]
    if f.get("crashed") or f.get("signal") is not None:
        problems.append("%s exited on signal %s" % (name, f.get("signal")))
    if f.get("hung") or (f.get("longestOperationMs") or 0) > 5000:
        problems.append("%s hung or had an operation over 5 s" % name)
    if f.get("fdsAfter", 0) > f.get("fdsBefore", 0) + 2 or f.get("threadsAfter", 0) > f.get("threadsBefore", 0) + 2:
        problems.append("%s leaked descriptors or threads" % name)
    if f.get("mismatch"):
        problems.append("%s does not match its expectation: %s" % (name, "; ".join(f.get("problems") or [])))
    if f.get("outcome") != "played":
        p = f.get("problem") or {}
        if not (p.get("title") or "").strip() or not (p.get("explanation") or "").strip():
            problems.append("%s (%s) has no problem copy" % (name, f.get("outcome")))
by_name = {f["file"].rsplit("/", 1)[-1]: f for f in files}
if which == "odd":
    odd_kinds = {"zero.mkv": "notMedia", "text.mp4": "notMedia", "random.mkv": "notMedia", "prores.mov": "unsupportedCodec"}
    for name, want in odd_kinds.items():
        got = (by_name.get(name) or {}).get("outcome")
        if got != want:
            problems.append("%s is %s, expected %s" % (name, got, want))
    for name, f in by_name.items():
        if name not in odd_kinds and f.get("outcome") != "played":
            problems.append("%s is %s, expected played" % (name, f.get("outcome")))
else:
    manifest = json.load(open(manifest_path))["files"]
    cut = reached = 0
    for e in manifest:
        f = by_name.get(e["file"])
        if f is None:
            problems.append("%s is missing from the report" % e["file"])
            continue
        played = f.get("outcome") == "played"
        if e.get("dataEnd") is not None and e["family"] in ("mp4-faststart", "matroska"):
            cut += 1
            end = f.get("dataEnd")
            if not played or end is None or abs(end - e["dataEnd"]) > 1.0:
                problems.append("%s dataEnd %s, expected %s within 1 s" % (e["file"], end, e["dataEnd"]))
        if e["mutation"] in ("zeromid", "overwrite50") and played and e.get("damage"):
            reached += 1
            end = f.get("dataEnd") or f.get("durationSeconds") or 0
            if not f.get("ended") and f.get("reachedSeconds", 0) + 1.0 < end:
                problems.append("%s stopped at %s s of %s s" % (e["file"], f.get("reachedSeconds"), end))
            if e["damage"].get("video") and not f.get("damagedFrames"):
                problems.append("%s counted no damaged frames" % e["file"])
    parts.append("%d cut-short files checked against dataEnd, %d damaged files played through" % (cut, reached))
'

ASAN_SCRATCH="${TMPDIR:-/tmp}"
ASAN_SCRATCH="${ASAN_SCRATCH%/}/reel-asan"

# Deletes only the exact scratch path the ASan build used.
asan_cleanup() {
  case "$ASAN_SCRATCH" in
    */reel-asan) [ -d "$ASAN_SCRATCH" ] && rm -rf -- "$ASAN_SCRATCH" ;;
  esac
  return 0
}

# Three files per base (a half-length truncation, a zero-filled middle and a bit-flip file).
asan_files() {
  python3 -I -c '
import json, sys
folder = sys.argv[1]
entries = json.load(open(folder + "/manifest.json"))["files"]
for base in sorted({e["base"] for e in entries}):
    for mutation in ("trunc50", "zeromid", "bitflip1"):
        for e in entries:
            if e["base"] == base and e["mutation"] == mutation:
                print(folder + "/" + e["file"])
' "$1"
}

ac_m3_5() {
  local F="$FIXTURES" files=() line asan_bin out rc
  if [ ! -f "$F/corpus/manifest.json" ] || [ ! -d "$F/odd" ]; then
    fail AC-M3-5 "corpus or odd fixtures missing in $F (run scripts/fixtures.sh)"
    return
  fi
  run_ctl soak-corpus soak "$F/corpus" --seed 1 --ops 30 --json || true
  m2_eval "corpus" "$RUN/soak-corpus.json" "$SOAK_CHECK" corpus "$F/corpus/manifest.json"
  run_ctl soak-odd soak "$F/odd" --seed 1 --ops 30 --json || true
  m2_eval "odd" "$RUN/soak-odd.json" "$SOAK_CHECK" odd none
  m2_suite RobustnessTests
  m2_suite OddFileTests
  # AddressSanitizer on 24 corpus files, in its own scratch path that is deleted afterwards.
  ACCEPT_EXTRA_CLEANUP=asan_cleanup
  while IFS= read -r line; do files+=("$line"); done < <(asan_files "$F/corpus")
  if [ "${#files[@]}" -ne 24 ]; then
    m2_step "AddressSanitizer" "expected 24 files, found ${#files[@]}" 1
  elif run_logged asan-build caffeinate -i swift build -c debug --sanitize=address --product reelctl \
    --package-path "$REPO" --scratch-path "$ASAN_SCRATCH"; then
    asan_bin="$(swift build -c debug --sanitize=address --package-path "$REPO" --scratch-path "$ASAN_SCRATCH" --show-bin-path 2>/dev/null || true)/reelctl"
    if [ -x "$asan_bin" ]; then
      local home
      home="$(fresh_home)"
      note "asan soak: ${#files[@]} files"
      REEL_HOME="$home" REEL_IINA_WATCH_LATER="" "$asan_bin" soak --list "${files[@]}" --seed 2 --ops 20 --json \
        >"$RUN/soak-asan.json" 2>"$RUN/soak-asan.err"
      rc=$?
      remove_run_path "$home"
      out="$(py_check "$RUN/soak-asan.json" '
t = r.get("totals") or {}
parts.append("%d files, crashes %s, hangs %s, played %s, classified %s" % (t.get("files", 0), t.get("crashes"), t.get("hangs"), t.get("played"), t.get("classified")))
if t.get("files") != 24:
    problems.append("not 24 files")
if t.get("crashes") != 0:
    problems.append("crashes %s" % t.get("crashes"))
for f in r.get("files") or []:
    if any("sanitizer" in p for p in f.get("problems") or []):
        problems.append("%s has a sanitizer report" % f["file"].rsplit("/", 1)[-1])
' 2>&1)"
      local py=$?
      if grep -q AddressSanitizer "$RUN/soak-asan.err"; then
        out="$out [AddressSanitizer line on standard error, see $RUN/soak-asan.err]"
        py=1
      fi
      [ $rc -le 1 ] || { out="$out [soak exit $rc]"; py=1; }
      m2_step "AddressSanitizer soak" "$out" $py
    else
      m2_step "AddressSanitizer soak" "no reelctl at $asan_bin" 1
    fi
  else
    m2_step "AddressSanitizer build" "failed, see $RUN/asan-build.log" 1
  fi
  asan_cleanup
  m2_finish AC-M3-5 "damaged and odd files"
}

# ---------------------------------------------------------------------------------------------
# AC-M3-6
# ---------------------------------------------------------------------------------------------

M3_SCENARIOS="hdr-badge video-info hdr-sdr dv-note open-failed truncated damaged-osd drive-gone"
# The video-info panel: 344 pt wide, 20 pt from the right and 48 pt from the top (9.13), at 2x.
VIDEO_INFO_RECT="1840 100 640 660"
# The title bar text of open-failed (the card itself is white on black in both appearances).
TITLE_TEXT_RECT="560 24 1440 72"

m3_region() {
  case "$1" in
    video-info) echo "$VIDEO_INFO_RECT" ;;
    open-failed) echo "$TITLE_TEXT_RECT" ;;
    *) echo "$CTRL_RECT" ;;
  esac
}

# The 203-nit patch of the PQ ramp inside hdr-badge, from the generator's own rectangle (the
# shot shows the 1920x1080 ramp at 2560x1440): the central half of the patch, as "x y w h".
hdr_patch_rect() {
  python3 -I -c '
import json, sys
ramps = json.load(open(sys.argv[1]))["pq"]
scale = 2560.0 / ramps["width"]
for p in ramps["patches"]:
    if p["name"] == "203 nits":
        r = p["rect"]
        print(int((r["x"] + r["w"] / 4) * scale), int((r["y"] + r["h"] / 4) * scale), int(r["w"] / 2 * scale), int(r["h"] / 2 * scale))
' "$FIXTURES/logs/ramps.json"
}

ac_m3_6() {
  local problems="" scn mode f stats width height low high light dark diff count=0 lines n bad registered rect patch r g b luma
  run_shots_once
  note "lsappinfo front before: $SHOTS_BEFORE"
  note "lsappinfo front after: $SHOTS_AFTER"
  if [ "$SHOTS_RC" -ne 0 ]; then
    case $SHOTS_RC in
      3) problems="$problems [frontmost app changed]" ;;
      4) problems="$problems [an on-screen window appeared]" ;;
      5) problems="$problems [a shot process registered as an application]" ;;
      *) problems="$problems [shots.sh exit $SHOTS_RC, see $RUN/all-shots.log]" ;;
    esac
  fi
  [ "$SHOTS_BEFORE" = "$SHOTS_AFTER" ] || problems="$problems [lsappinfo front changed: $SHOTS_BEFORE -> $SHOTS_AFTER]"
  for scn in $M3_SCENARIOS; do
    for mode in light dark; do
      f="$REPO/build/shots/$scn-$mode.png"
      if [ ! -s "$f" ]; then
        problems="$problems [missing $scn-$mode.png]"
        continue
      fi
      stats="$("$TOOLS/shot-stats" "$f" 2>/dev/null || true)"
      width="$(echo "$stats" | awk '{print $1}')"
      height="$(echo "$stats" | awk '{print $2}')"
      low="$(echo "$stats" | awk '{print $5}')"
      high="$(echo "$stats" | awk '{print $6}')"
      if [ "$width" != 2560 ] || [ "$height" != 1440 ]; then
        problems="$problems [$scn-$mode is ${width:-?}x${height:-?}]"
      elif ! awk -v lo="${low:-0}" -v hi="${high:-0}" 'BEGIN { exit !(hi - lo >= 16) }'; then
        problems="$problems [$scn-$mode is blank, luminance $low to $high]"
      else
        count=$((count + 1))
      fi
    done
    rect="$(m3_region "$scn")"
    # shellcheck disable=SC2086
    light="$("$TOOLS/shot-stats" "$REPO/build/shots/$scn-light.png" $rect 2>/dev/null | awk '{print $3}')"
    # shellcheck disable=SC2086
    dark="$("$TOOLS/shot-stats" "$REPO/build/shots/$scn-dark.png" $rect 2>/dev/null | awk '{print $3}')"
    if [ -z "$light" ] || [ -z "$dark" ]; then
      problems="$problems [no region stats for $scn]"
      continue
    fi
    diff="$(awk -v a="$light" -v b="$dark" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.1f", d }')"
    if [ "$scn" = open-failed ]; then
      # The card sits on black in both appearances; only the title bar text must be drawn.
      # shellcheck disable=SC2086
      stats="$("$TOOLS/shot-stats" "$REPO/build/shots/$scn-light.png" $rect 2>/dev/null || true)"
      note "$scn title bar text region, light: $stats"
      awk -v lo="$(echo "$stats" | awk '{print $5}')" -v hi="$(echo "$stats" | awk '{print $6}')" 'BEGIN { exit !(hi - lo >= 16) }' \
        || problems="$problems [open-failed title bar text region is blank]"
    else
      note "$scn region luminance light $light dark $dark diff $diff"
      awk -v d="$diff" 'BEGIN { exit !(d >= 40) }' || problems="$problems [$scn light/dark differ by only $diff/255 in its controller or panel region]"
    fi
  done
  patch="$(hdr_patch_rect)"
  for mode in light dark; do
    # shellcheck disable=SC2086
    read -r r g b <<<"$("$TOOLS/shot-stats" "$REPO/build/shots/hdr-badge-$mode.png" --patch $patch 2>/dev/null)"
    luma="$(awk -v r="${r:-0}" -v g="${g:-0}" -v b="${b:-0}" 'BEGIN { printf "%.1f", 0.2126 * r + 0.7152 * g + 0.0722 * b }')"
    note "hdr-badge-$mode 203-nit patch ($patch) mean rgb ${r:-?} ${g:-?} ${b:-?}, luma $luma"
    awk -v l="$luma" 'BEGIN { exit !(l >= 190 && l <= 250) }' || problems="$problems [hdr-badge-$mode 203-nit patch luma $luma outside 190 to 250]"
  done
  # Every launch recorded the frontmost app before and after; the M3 ones must match.
  lines="$(grep -E "^($(echo "$M3_SCENARIOS" | tr ' ' '|')) (light|dark) pid=" "$RUN/shots-all.log" 2>/dev/null | sed -n 's/.* before=\[\(.*\)\] after=\[\(.*\)\]$/\1|\2/p' || true)"
  n="$(echo "$lines" | grep -c . || true)"
  bad="$(echo "$lines" | awk -F'|' 'NF && $1 != $2' | wc -l | tr -d ' ')"
  registered="$(grep -E "^($(echo "$M3_SCENARIOS" | tr ' ' '|')) (light|dark) pid=" "$RUN/shots-all.log" 2>/dev/null | grep -c ' app=\[[^n]' || true)"
  note "shots.log: $n M3 launches, $bad with a changed frontmost app, ${registered:-0} registered as an application"
  [ "$n" -eq 16 ] || problems="$problems [shots.log has $n M3 launches, expected 16]"
  [ "$bad" -eq 0 ] || problems="$problems [shots.log shows $bad launches that changed the frontmost app]"
  [ "${registered:-0}" -eq 0 ] || problems="$problems [shots.log shows $registered launches registered as an application]"
  if [ -n "$problems" ]; then
    fail AC-M3-6 "screenshots:$problems"
  else
    pass AC-M3-6 "$count PNGs at 2560x1440, not blank, light/dark regions differ, 203-nit patch luma within 190 to 250 in both, $n launches with before == after, front unchanged ($SHOTS_AFTER), no window"
  fi
}

# ---------------------------------------------------------------------------------------------
# AC-M3-7
# ---------------------------------------------------------------------------------------------

ac_m3_7() {
  local t
  m3_test InputMapTests videoInfoIsCommandI
  m3_test InputMapTests addSubtitleFileIsShiftCommandO
  m3_test MainMenuM3Tests videoInfoAndAddSubtitleFileShowTheirShortcuts
  m3_test PlayerModelM3Tests theVKeyNamesItselfAndVisibilityResetsOnTheNextFile
  run_ctl devices devices --json || true
  m2_eval "reelctl devices" "$RUN/devices.json" '
devices = r.get("devices") or []
defaults = [d for d in devices if d.get("isDefault")]
named = [d for d in devices if d.get("uid") and d.get("name")]
parts.append("%d devices, %d with uid and name, %d default (%s)" % (len(devices), len(named), len(defaults), ", ".join(d.get("name", "?") for d in defaults)))
if not devices:
    problems.append("no output device listed")
if len(named) != len(devices):
    problems.append("a device has an empty uid or name")
if len(defaults) != 1:
    problems.append("isDefault is set on %d devices, expected 1" % len(defaults))
'
  for t in aStoredUIDResolvesWhenPresent aMissingDeviceFallsBackToSystemDefaultWithAnOSD choiceRoundTripsThroughStateJSON; do
    m3_test OutputDeviceChoiceTests "$t"
  done
  m2_suite OutputDeviceChoiceTests
  m3_test SettingsM3Tests settingsHavePlaybackVideoAndAudioGroupsWithTheM3Rows
  m2_finish AC-M3-7 "small items"
}

# ---------------------------------------------------------------------------------------------
# AC-M3-8
# ---------------------------------------------------------------------------------------------

# One `reelctl color` report: <file name> <primaries> <transfer> <matrix>.
COLOR_CODE='
name, primaries, transfer, matrix = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
a = r.get("attachments") or {}
patches = r.get("patches") or []
worst = max([p.get("difference", 99) for p in patches] or [99])
worst_patch = max(patches, key=lambda p: p.get("difference", 0)) if patches else {}
not_flat = [p["name"] for p in patches if not p.get("flat")]
parts.append("%s: %d patches, max difference %s (%s reel %s quicktime %s), %s %s %s, ICC %s" % (
    r.get("decoder"), len(patches), worst, worst_patch.get("name"), worst_patch.get("reel"), worst_patch.get("quickTime"),
    a.get("primaries"), a.get("transfer"), a.get("matrix"), r.get("screenshotICCProfile")))
if len(patches) != 24:
    problems.append("expected 24 patches")
if not_flat:
    problems.append("patches not flat: " + ",".join(not_flat))
if worst > 3:
    problems.append("a patch differs from AVAssetImageGenerator by more than 3 codes")
if (a.get("primaries"), a.get("transfer"), a.get("matrix")) != (primaries, transfer, matrix):
    problems.append("attachments are not %s, %s, %s" % (primaries, transfer, matrix))
if r.get("screenshotICCProfile") is not True:
    problems.append("the screenshot has no ICC profile")
if r.get("reelColorSpaceIsDeviceRGB"):
    problems.append("the image is in device RGB")
'

ac_m3_8() {
  local F="$FIXTURES/sdr" spec file primaries transfer matrix decoder tag
  if [ ! -f "$F/bars709_h264.mp4" ]; then
    fail AC-M3-8 "sdr fixtures missing in $F (run scripts/fixtures.sh)"
    return
  fi
  for spec in "bars709_h264.mp4 ITU_R_709_2 ITU_R_709_2 ITU_R_709_2" \
    "bars709_untagged_h264.mp4 ITU_R_709_2 ITU_R_709_2 ITU_R_709_2" \
    "bars601_sd_h264.mp4 SMPTE_C ITU_R_709_2 ITU_R_601_4"; do
    # shellcheck disable=SC2086
    set -- $spec
    file=$1 primaries=$2 transfer=$3 matrix=$4
    for decoder in hw sw; do
      tag="color-$file-$decoder"
      run_ctl "$tag" color "$F/$file" --frame 12 --decoder $decoder --screenshot "$RUN/$tag.png" --json || true
      m2_eval "$file $decoder" "$RUN/$tag.json" "$COLOR_CODE" "$file" "$primaries" "$transfer" "$matrix"
    done
  done
  m2_suite ColorPipelineTests
  m3_test DynamicRangeLayerTests displayLayerColorspaceAndFiltersAreNeverOverridden
  m2_finish AC-M3-8 "SDR colour against AVAssetImageGenerator"
}

# ---------------------------------------------------------------------------------------------
# AC-M3-9
# ---------------------------------------------------------------------------------------------

ac_m3_9() {
  local F="$FIXTURES/hdr" file tag
  for file in pq_ramp_hevc.mkv hlg_ramp_hevc.mp4; do
    tag="headroom1-$file"
    run_ctl "$tag" hdr "$F/$file" --display-headroom 1.0 --json || true
    m2_eval "$file headroom 1.0" "$RUN/$tag.json" '
t = r.get("toneMapped") or {}
lumas = t.get("lumas") or []
hlg = r.get("kind") == "hlg"
# The ramp up to its 1000-nit patch: PQ 0 to 1000 nits is the first 8 patches; HLG signal 1.0 is 1000 nits.
ramp = lumas if hlg else lumas[:8]
white = t.get("referenceWhiteValue")
parts.append("presentation %s, lumas %s, white %s" % (r.get("presentation"), lumas, white))
if r.get("presentation") != "toneMapToSDR":
    problems.append("presentation is not toneMapToSDR")
if white is None or not 225 <= white <= 255:
    problems.append("reference white outside 225 to 255")
if len(ramp) < 2 or any(not a < b for a, b in zip(ramp, ramp[1:])):
    problems.append("the ramp up to 1000 nits is not strictly increasing")
if not lumas or lumas[0] > 8:
    problems.append("the 0-nit patch is over 8")
'
    tag="headroom4-$file"
    run_ctl "$tag" hdr "$F/$file" --display-headroom 4.0 --json || true
    m2_eval "$file headroom 4.0" "$RUN/$tag.json" '
parts.append("presentation %s" % r.get("presentation"))
if r.get("presentation") != "edr":
    problems.append("presentation is not edr")
'
  done
  m3_test DynamicRangePlanTests headroomOneIsToneMappedAndFourIsEDR
  m3_test DynamicRangePlanTests displayChangeAtRuntimeKeepsTheLayer
  m2_finish AC-M3-9 "HDR on a display without headroom"
}

# ---------------------------------------------------------------------------------------------
# AC-M3-10
# ---------------------------------------------------------------------------------------------

ac_m3_10() {
  local t doc="$REPO/docs/superpowers/specs/2026-10-24-reel-design.md"
  for t in osdDropsItsScaleWithReduceMotion seekTrackSpringBecomesTheReducedFade volumeWidenJumpsWithReduceMotion \
    windowFrameDoesNotAnimateWithReduceMotion \
    anchorFollowsTheButtonWhenThePanelIsClamped dropTargetFollowsTheDragLifecycle chromeRevealIsMostlyOpaqueBy60Milliseconds; do
    m3_test MotionTests "$t"
  done
  m2_suite MotionTests
  # Section 15.2 runs from its heading to the 15.3 heading.
  if awk '/^### 15\.2 /{in152=1; next} /^### 15\.3 /{in152=0} in152' "$doc" | grep -q "Subtitle lift up | bottom lines snap up"; then
    m2_step "design 15.2" "the subtitle lift snaps" 0
  else
    m2_step "design 15.2" "does not say the subtitle lift snaps" 1
  fi
  m2_finish AC-M3-10 "motion gate fixes"
}

group_m3() {
  echo
  echo "== m3"
  ac_m3_1
  if [ -x "${CTL:-}" ]; then
    ac_m3_2
    ac_m3_3
    ac_m3_4
    ac_m3_5
  else
    fail AC-M3-2 "no reelctl"
    fail AC-M3-3 "no reelctl"
    fail AC-M3-4 "no reelctl"
    fail AC-M3-5 "no reelctl"
  fi
  ac_m3_6
  if [ -x "${CTL:-}" ]; then
    ac_m3_7
    ac_m3_8
    ac_m3_9
  else
    fail AC-M3-7 "no reelctl"
    fail AC-M3-8 "no reelctl"
    fail AC-M3-9 "no reelctl"
  fi
  ac_m3_10
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
  group_m2
  group_m3
}

case "$GROUP" in
  offline) group_offline ;;
  m2)
    CTL="$(reelctl_path)"
    group_m2
    ;;
  m3)
    CTL="$(reelctl_path)"
    group_m3
    ;;
esac

echo
FAILS="$(awk -F'\t' '$2 == "FAIL"' "$RESULTS" | wc -l | tr -d ' ')"
PASSES="$(awk -F'\t' '$2 == "PASS"' "$RESULTS" | wc -l | tr -d ' ')"
echo "Results: $RESULTS ($PASSES PASS, $FAILS FAIL)"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
