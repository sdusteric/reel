#!/usr/bin/env bash
# Renders every frame of docs/mockup/index.html to docs/mockup/png/<frame>-<theme>.png with
# headless Chrome (--headless=new never shows a window). A throwaway profile from mktemp, no
# network (every host maps to NOTFOUND), each Chrome tracked and stopped by its own PID.
# The frontmost app is read with lsappinfo before and after every frame; a change fails the run.
#
# Usage: docs/mockup/render.sh [frame-id ...]     default: all frames
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="$HERE/png"
PAGE="file://$HERE/index.html"
mkdir -p "$OUT"

# id themes width height scale
FRAMES=(
  "01-controller light,dark 1280 720 2"
  "02-subtitle-menu light,dark 1280 720 2"
  "03-audio-menu light,dark 1280 720 2"
  "04-speed-menu light,dark 1280 720 2"
  "05-thumbnail-hover light,dark 1280 720 2"
  "06-thumbnail-scrub light,dark 1280 720 2"
  "07-subtitles-bilingual dark 1280 720 2"
  "08-subtitles-srt-bright dark 1280 720 2"
  "09-subtitles-lifted light,dark 1280 720 2"
  "10-osd-speed light,dark 1280 720 2"
  "11-osd-subtitle-delay light,dark 1280 720 2"
  "12-osd-loop-set light,dark 1280 720 2"
  "13-osd-loop-cleared light,dark 1280 720 2"
  "14-next-episode light,dark 1280 720 2"
  "15-fullscreen light,dark 2560 1440 2"
  "16-pip light,dark 1280 720 2"
  "17-menus light,dark 1280 720 2"
  "18-edge-states light,dark 1280 720 2"
)

front() { lsappinfo info -only name "$(lsappinfo front 2>/dev/null)" 2>/dev/null | head -1 | tr -d '\n'; echo " $(lsappinfo front 2>/dev/null)"; }

PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/reel-mockup-chrome.XXXXXX")"
PID=""
cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then kill -TERM "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  case "$PROFILE" in "${TMPDIR:-/tmp}"/reel-mockup-chrome.?*) rm -rf -- "$PROFILE" ;; esac
}
trap cleanup EXIT

START_FRONT="$(front)"
echo "front before: $START_FRONT"

shoot() { # id theme w h scale
  local id="$1" theme="$2" w="$3" h="$4" scale="$5" out before after
  out="$OUT/$id-$theme.png"
  before="$(front)"
  "$CHROME" --headless=new --disable-gpu-sandbox --hide-scrollbars --no-first-run --no-default-browser-check \
    --disable-extensions --disable-sync --disable-background-networking --disable-component-update \
    --disable-default-apps --disable-features=Translate,MediaRouter,OptimizationHints,AutofillServerCommunication \
    --metrics-recording-only --host-resolver-rules="MAP * ~NOTFOUND" --mute-audio \
    --user-data-dir="$PROFILE" --allow-file-access-from-files \
    --window-size="$w,$h" --force-device-scale-factor="$scale" --virtual-time-budget=3000 \
    --screenshot="$out" "$PAGE?frame=$id&theme=$theme" >/dev/null 2>&1 &
  PID=$!
  local waited=0
  while kill -0 "$PID" 2>/dev/null; do
    sleep 0.2; waited=$((waited + 1))
    if [ "$waited" -gt 150 ]; then echo "timeout on $id-$theme, stopping pid $PID" >&2; kill -TERM "$PID" 2>/dev/null || true; break; fi
  done
  wait "$PID" 2>/dev/null || true
  PID=""
  after="$(front)"
  if [ "$before" != "$after" ]; then echo "frontmost app changed during $id-$theme: [$before] -> [$after]" >&2; exit 3; fi
  [ -s "$out" ] || { echo "no output for $id-$theme" >&2; exit 1; }
  echo "ok $id-$theme $(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w "x" h}')"
}

for line in "${FRAMES[@]}"; do
  read -r id themes w h scale <<<"$line"
  if [ $# -gt 0 ]; then
    wanted=0; for a in "$@"; do [ "$a" = "$id" ] && wanted=1; done
    [ "$wanted" = 1 ] || continue
  fi
  IFS=, read -r -a list <<<"$themes"
  for theme in "${list[@]}"; do shoot "$id" "$theme" "$w" "$h" "$scale"; done
done

END_FRONT="$(front)"
echo "front after: $END_FRONT"
[ "$START_FRONT" = "$END_FRONT" ] || { echo "frontmost app changed" >&2; exit 3; }
