#!/usr/bin/env bash
# Reel acceptance runner (milestones 1 and 2).
#
#   scripts/accept.sh offline    M1 criteria AC01 to AC05, then the M2 group
#   scripts/accept.sh m2         only the M2 group (AC-M2-1 to AC-M2-6)
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
#         ChromeVisibilityTests, OpenAndDropTests, SeekTests and the M2 suites. A missing suite
#         is a FAIL.
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
#   AC-M2-5  scripts/shots.sh for all 16 scenarios in light and dark: 32 PNGs at 2560x1440, not
#            blank, controller regions differ, outlined subtitle ink, frontmost app unchanged.
#   AC-M2-6  VP9 hybrid seek-bench thresholds, and M1's AC02 and AC03 passing in the same run.
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
  offline | m2) ;;
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
  for suite in $REQUIRED_SUITES $M2_SUITES; do
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

M2_SCENARIOS="empty playing paused-osd scrubbing subtitle-panel audio-panel speed-panel thumbnail subtitles subtitles-lifted osd-speed osd-loop next-episode pip fullscreen edge-states"
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
  if [ ! -x "$APP/Contents/MacOS/Reel" ]; then
    run_logged bundle "$REPO/scripts/bundle.sh" --release || true
  fi
  before="$(front)"
  note "lsappinfo front before: $before"
  run_logged m2-shots "$REPO/scripts/shots.sh"
  rc=$?
  after="$(front)"
  note "lsappinfo front after: $after"
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
  log="$REPO/build/shots/shots.log"
  lines="$(sed -n 's/.* before=\[\(.*\)\] after=\[\(.*\)\]$/\1|\2/p' "$log" 2>/dev/null || true)"
  n_launches="$(echo "$lines" | grep -c . || true)"
  bad="$(echo "$lines" | awk -F'|' 'NF && $1 != $2' | wc -l | tr -d ' ')"
  note "shots.log: $n_launches launches, $bad with a changed frontmost app"
  [ "$n_launches" -eq 32 ] || problems="$problems [shots.log has $n_launches launches, expected 32]"
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
}

case "$GROUP" in
  offline) group_offline ;;
  m2)
    CTL="$(reelctl_path)"
    group_m2
    ;;
esac

echo
FAILS="$(awk -F'\t' '$2 == "FAIL"' "$RESULTS" | wc -l | tr -d ' ')"
PASSES="$(awk -F'\t' '$2 == "PASS"' "$RESULTS" | wc -l | tr -d ' ')"
echo "Results: $RESULTS ($PASSES PASS, $FAILS FAIL)"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
