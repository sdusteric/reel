#!/usr/bin/env bash
# Generates Reel's test media (design section 14) with Homebrew ffmpeg, used only as a generator.
# Every file comes from lavfi sources (testsrc2 plus temporal noise, colour, sine, aevalsrc),
# subtitle text written by this script and a PGS stream from scripts/make-pgs.swift, and (M3)
# raw patch ramps from scripts/make-ramp.py, Dolby Vision records from scripts/make-dovi.py and
# damaged copies from scripts/make-corpus.py (all run with python3 -I, standard library only);
# nothing is read from the user's media.
#
# Usage: scripts/fixtures.sh            output: ${REEL_FIXTURES:-<repo>/build/fixtures}
# Env:   FORCE=1 regenerates everything.
#
# The stamp file .fixtures-<script hash> is written last; when it matches and every file is
# present the script exits at once. Encodes run in parallel, tracked and awaited by PID.
# The M3 recipes sit between '# >>> m3' and '# <<< m3' lines and have their own version, so
# changing them never regenerates the M1 and M2 files, and the reverse.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REEL_FIXTURES:-$ROOT/build/fixtures}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
LOGS="$OUT/logs"
mkdir -p "$LOGS"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
FFMPEG="$(command -v ffmpeg || true)"
if [ -z "$FFMPEG" ]; then
  echo "ffmpeg not found (looked in /opt/homebrew/bin, /usr/local/bin and PATH)" >&2
  exit 1
fi
FFPROBE="$(dirname "$FFMPEG")/ffprobe"
[ -x "$FFPROBE" ] || { echo "ffprobe not found next to $FFMPEG" >&2; exit 1; }
for encoder in libx265 libx264 libsvtav1 libvpx-vp9 libopus ac3 aac mpeg4 flv libmp3lame prores_ks mjpeg; do
  if ! "$FFMPEG" -hide_banner -encoders 2>/dev/null | awk '{print $2}' | grep -qx "$encoder"; then
    echo "ffmpeg at $FFMPEG lacks the $encoder encoder" >&2
    exit 1
  fi
done

FIXTURES=(
  hevc10_1080p24.mkv av1_2160p60.mkv h264_1080p30.mp4 vp9_2160p60.webm
  sync_h264_aac.mp4 sync_hevc_opus.mkv
  hdr10_hevc.mkv rot90_h264.mov annexb_h264.ts mpeg4.avi flv1.flv nocues_hevc.mkv
  subs_tracks.mkv subs_tracks.zh-Hans.srt subs_utf8.srt subs_gbk.srt subs_big5.cht.srt subs_ass_signs.ass
  pgs_fixture.sup subs_pgs.mkv logs/pgs_rects.json
  episodes/Northern.Line.S01E01.mkv episodes/Northern.Line.S01E02.mkv episodes/Northern.Line.S01E03.mkv
  episodes/Northern.Line.S01E10.mkv episodes/._Northern.Line.S01E02.mkv episodes/notes.txt
)

# >>> m3
# M3 fixtures (design sections 7.7, 7.8, 7.10 and 14). The long name has 240 characters, CJK and
# emoji, 250 UTF-16 units (APFS allows 255).
LONG_NAME="$(python3 -I -c 'print(("北線終點站的長夜與清晨" * 30)[:226] + "🚇🌃" * 5 + ".mkv")')"
CORPUS_BASES=(h264_moov_end.mp4 h264_faststart.mp4 hevc.mkv av1.mkv vp9.webm h264.ts mpeg4.avi flv1.flv)
M3_FIXTURES=(
  logs/ramps.json
  hdr/pq_ramp_hevc.mkv hdr/pq_ramp_hevc.mp4 hdr/hlg_ramp_hevc.mkv hdr/hlg_ramp_hevc.mp4
  hdr/pq_ramp_av1.mkv hdr/pq_ramp_vp9.webm hdr/sdr_ramp_h264.mp4
  hdr/dv81.mp4 hdr/dv81.mkv hdr/dv84.mp4 hdr/dv5.mp4
  odd/zero.mkv odd/text.mp4 odd/random.mkv odd/prores.mov odd/audio_cover.mp3 odd/video_only.mp4
  odd/one_frame.mkv odd/tiny_16x16.mp4 odd/odd_1921x1081.mkv odd/res_change.ts odd/layout_change.ts
  odd/ts_wrap.ts odd/vfr.mkv odd/intra_refresh.mp4 odd/h264_422_10bit.mkv odd/h264_444.mkv
  odd/edit_list_offset.mp4 odd/many_tracks.mkv "odd/$LONG_NAME"
  corpus/manifest.json
)
for base in "${CORPUS_BASES[@]}"; do M3_FIXTURES+=("corpus/$base"); done
# <<< m3

# >>> m3-color
# SDR colour bars for AC-M3-8 (design section 7.9): a 6 x 4 grid of flat patches, so each patch
# centre that `reelctl color` measures is far from an edge. Tagged BT.709, untagged HD (Reel
# treats it as BT.709) and untagged SD at 704 x 480 (treated as SMPTE 170M, as VideoToolbox does
# for QuickTime up to 704 x 576; it reads untagged 720 x 480 as BT.709).
COLOR_FIXTURES=(sdr/bars709_h264.mp4 sdr/bars709_untagged_h264.mp4 sdr/bars601_sd_h264.mp4)
# <<< m3-color

# >>> m3-dovi
# Dolby Vision with real RPUs (design section 7.8): the ramps re-encoded by scripts/make-dovi-rpu.c
# (Homebrew's libavcodec and libx265 with Dolby Vision metadata on every frame), so AVFoundation
# and VideoToolbox see real profile 8.1, 8.4 and 5 streams.
DOVI_RPU_FIXTURES=(hdr/dv81_rpu.mp4 hdr/dv84_rpu.mp4 hdr/dv5_rpu.mp4)
# <<< m3-dovi

# >>> m3-reorder
# B-frames with decode-order pts: MP4 files whose ctts box is gone (as in many x265 remuxes), so
# every pts equals its dts and only the picture order count gives the display order; an MKV
# remuxed from one (pts rise in decode order); AVI files, which store no pts at all (H.264, and
# MPEG-4 Part 2 as XviD writes it); raw H.264 and HEVC streams, which have no times at all.
REORDER_FIXTURES=(
  reorder/hevc_open_gop_no_ctts.mp4 reorder/h264_no_ctts.mp4 reorder/hevc_no_ctts_remux.mkv reorder/h264_bframes.avi
  reorder/mpeg4_bframes.avi reorder/raw_bframes.h264 reorder/raw_open_gop.hevc
)
# <<< m3-reorder

# >>> m3-mpeg2
# MPEG-2 in program streams (DVD .vob, .mpg) and a transport stream (TV recordings), and
# interlaced video with motion (MPEG-2 and MBAFF H.264, top field first) for the deinterlacer.
MPEG2_FIXTURES=(
  mpeg2/sync_mpeg2_mp2.mpg mpeg2/sync_mpeg2_ac3.vob mpeg2/ramp_mpeg2.ts
  interlaced/mpeg2_tff.ts interlaced/h264_mbaff_tff.ts
)
# <<< m3-mpeg2

# Version groups: the M1 and M2 recipes (everything outside the m3 blocks) and the M3 recipes
# (the m3 blocks and the Python generators). The stamp covers both.
# The SDR colour bars ('# >>> m3-color' blocks) are a third group, so adding them regenerated
# neither the M1 and M2 files nor the M3 corpus.
strip_m3() { awk '/^# >>> m3/{skip=1} !skip{print} /^# <<< m3/{skip=0}' "$1"; }
only_m3() { awk '/^# >>> m3$/{keep=1} keep{print} /^# <<< m3$/{keep=0}' "$1"; }
only_color() { awk '/^# >>> m3-color$/{keep=1} keep{print} /^# <<< m3-color$/{keep=0}' "$1"; }
only_dovi() { awk '/^# >>> m3-dovi$/{keep=1} keep{print} /^# <<< m3-dovi$/{keep=0}' "$1"; }
only_reorder() { awk '/^# >>> m3-reorder$/{keep=1} keep{print} /^# <<< m3-reorder$/{keep=0}' "$1"; }
only_mpeg2() { awk '/^# >>> m3-mpeg2$/{keep=1} keep{print} /^# <<< m3-mpeg2$/{keep=0}' "$1"; }
BASE_HASH="$(strip_m3 "${BASH_SOURCE[0]}" | shasum -a 256 | cut -c1-16)"
M3_HASH="$({ only_m3 "${BASH_SOURCE[0]}"; cat "$ROOT/scripts/make-ramp.py" "$ROOT/scripts/make-dovi.py" "$ROOT/scripts/make-corpus.py"; } | shasum -a 256 | cut -c1-16)"
COLOR_HASH="$(only_color "${BASH_SOURCE[0]}" | shasum -a 256 | cut -c1-16)"
# The Dolby Vision RPU files ('# >>> m3-dovi' blocks and make-dovi-rpu.c) are a fourth group.
DOVI_HASH="$({ only_dovi "${BASH_SOURCE[0]}"; cat "$ROOT/scripts/make-dovi-rpu.c"; } | shasum -a 256 | cut -c1-16)"
# The decode-order pts files ('# >>> m3-reorder' blocks) are a fifth group.
REORDER_HASH="$(only_reorder "${BASH_SOURCE[0]}" | shasum -a 256 | cut -c1-16)"
# The MPEG-2 files ('# >>> m3-mpeg2' blocks) are a sixth group.
MPEG2_HASH="$(only_mpeg2 "${BASH_SOURCE[0]}" | shasum -a 256 | cut -c1-16)"
SCRIPT_HASH="$(printf '%s %s %s %s %s %s\n' "$BASE_HASH" "$M3_HASH" "$COLOR_HASH" "$DOVI_HASH" "$REORDER_HASH" "$MPEG2_HASH" | shasum -a 256 | cut -c1-16)"
STAMP="$OUT/.fixtures-$SCRIPT_HASH"
# Base hashes of earlier versions whose M1 and M2 recipes are the ones here, so their files are
# kept: 9720b018b84371bc is the M2 script, 4c872f63da278f6a the M3 script before the colour group,
# 8b2af9c2e01cae4b the script before the reorder group, fb78bc447929b86a before the MPEG-2 group,
# 86bb7bf48b1f01e7 before the raw streams.
LEGACY_BASE_VERSIONS=(9720b018b84371bc 4c872f63da278f6a 8b2af9c2e01cae4b fb78bc447929b86a 86bb7bf48b1f01e7)

# Several agents and gates may run this at once: one generates, the others wait for its stamp.
LOCK="$OUT/.lock"
until mkdir "$LOCK" 2>/dev/null; do
  owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$owner" ] && ! ps -p "$owner" >/dev/null 2>&1; then
    rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true
    continue
  fi
  echo "waiting for another fixtures.sh (pid ${owner:-unknown})"
  sleep 5
done
echo $$ >"$LOCK/pid"
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true' EXIT

all_present() {
  local name
  for name in "${FIXTURES[@]}" "${M3_FIXTURES[@]}" "${COLOR_FIXTURES[@]}" "${DOVI_RPU_FIXTURES[@]}" "${REORDER_FIXTURES[@]}" "${MPEG2_FIXTURES[@]}"; do
    if [ "$name" = odd/zero.mkv ]; then
      [ -f "$OUT/$name" ] || return 1
    else
      [ -s "$OUT/$name" ] || return 1
    fi
  done
}

if [ -f "$STAMP" ] && [ "${FORCE:-0}" != 1 ] && all_present; then
  echo "Fixtures up to date in $OUT ($(basename "$STAMP")). Set FORCE=1 to regenerate."
  exit 0
fi

# A different script version invalidates every file; a rerun of an interrupted run of the
# same version keeps what it finished (each file is renamed into place only when complete).
VERSION_FILE="$OUT/.version"
M3_VERSION_FILE="$OUT/.version-m3"
COLOR_VERSION_FILE="$OUT/.version-m3-color"
DOVI_VERSION_FILE="$OUT/.version-m3-dovi"
REORDER_VERSION_FILE="$OUT/.version-m3-reorder"
MPEG2_VERSION_FILE="$OUT/.version-m3-mpeg2"
base_version="$(cat "$VERSION_FILE" 2>/dev/null || true)"
for legacy in "${LEGACY_BASE_VERSIONS[@]}"; do
  if [ "$base_version" = "$legacy" ]; then base_version="$BASE_HASH"; fi
done
if [ "${FORCE:-0}" = 1 ] || [ "$base_version" != "$BASE_HASH" ]; then
  for name in "${FIXTURES[@]}"; do rm -f "$OUT/$name"; done
fi
if [ "${FORCE:-0}" = 1 ] || [ "$(cat "$M3_VERSION_FILE" 2>/dev/null || true)" != "$M3_HASH" ]; then
  # Corpus copies are listed in the manifest; each is removed by its exact path.
  if [ -f "$OUT/corpus/manifest.json" ]; then
    python3 -I -c 'import json, sys; print("\n".join(e["file"] for e in json.load(open(sys.argv[1]))["files"]))' \
      "$OUT/corpus/manifest.json" | while IFS= read -r name; do rm -f "${OUT:?}/corpus/${name:?}"; done
  fi
  for name in "${M3_FIXTURES[@]}"; do rm -f "${OUT:?}/${name:?}"; done
fi
if [ "${FORCE:-0}" = 1 ] || [ "$(cat "$COLOR_VERSION_FILE" 2>/dev/null || true)" != "$COLOR_HASH" ]; then
  for name in "${COLOR_FIXTURES[@]}"; do rm -f "${OUT:?}/${name:?}"; done
fi
if [ "${FORCE:-0}" = 1 ] || [ "$(cat "$DOVI_VERSION_FILE" 2>/dev/null || true)" != "$DOVI_HASH" ]; then
  for name in "${DOVI_RPU_FIXTURES[@]}"; do rm -f "${OUT:?}/${name:?}"; done
fi
if [ "${FORCE:-0}" = 1 ] || [ "$(cat "$REORDER_VERSION_FILE" 2>/dev/null || true)" != "$REORDER_HASH" ]; then
  for name in "${REORDER_FIXTURES[@]}"; do rm -f "${OUT:?}/${name:?}"; done
fi
if [ "${FORCE:-0}" = 1 ] || [ "$(cat "$MPEG2_VERSION_FILE" 2>/dev/null || true)" != "$MPEG2_HASH" ]; then
  for name in "${MPEG2_FIXTURES[@]}"; do rm -f "${OUT:?}/${name:?}"; done
fi
rm -f "$OUT"/.fixtures-*
echo "$BASE_HASH" >"$VERSION_FILE"
echo "$M3_HASH" >"$M3_VERSION_FILE"
echo "$COLOR_HASH" >"$COLOR_VERSION_FILE"
echo "$DOVI_HASH" >"$DOVI_VERSION_FILE"
echo "$REORDER_HASH" >"$REORDER_VERSION_FILE"
echo "$MPEG2_HASH" >"$MPEG2_VERSION_FILE"

ff() { "$FFMPEG" -hide_banner -loglevel error -nostdin -y "$@"; }

# encode <name> <ffmpeg args...>: writes to a temp name, renames on success. <name> may be in a
# subfolder (episodes/...); the temp file is a hidden sibling so folder scans never list it.
encode() {
  local name="$1"; shift
  local ext="${name##*.}"
  local dir; dir="$(dirname "$OUT/$name")"
  local tmp; tmp="$dir/.partial-$(basename "$name")"
  local log; log="$LOGS/${name//\//_}.log"
  mkdir -p "$dir"
  rm -f "$tmp"
  local t0; t0=$(date +%s)
  if ff "$@" -f "$(muxer_for "$ext")" "$tmp" >"$log" 2>&1; then
    mv "$tmp" "$OUT/$name"
    echo "  $name ($(( $(date +%s) - t0 )) s)"
  else
    rm -f "$tmp"
    echo "FAILED $name, log: $log" >&2
    tail -20 "$log" >&2
    return 1
  fi
}

# put <name>: writes stdin to <name> through a temp file.
put() {
  local name="$1"
  local dir; dir="$(dirname "$OUT/$name")"
  mkdir -p "$dir"
  local tmp; tmp="$dir/.partial-$(basename "$name")"
  cat >"$tmp"
  mv "$tmp" "$OUT/$name"
}

muxer_for() {
  case "$1" in
    mkv) echo matroska ;;
    webm) echo webm ;;
    mp4) echo mp4 ;;
    mov) echo mov ;;
    ts) echo mpegts ;;
    mpg) echo mpeg ;;
    h264) echo h264 ;;
    hevc) echo hevc ;;
    vob) echo vob ;;
    avi) echo avi ;;
    flv) echo flv ;;
    mp3) echo mp3 ;;
    *) echo "unknown extension $1" >&2; return 1 ;;
  esac
}

PIDS=()
NAMES=()
start() { # start <name> <encode args...>
  local name="$1"
  if [ -s "$OUT/$name" ]; then echo "  $name (kept)"; return 0; fi
  encode "$@" &
  PIDS+=("$!")
  NAMES+=("$name")
}

FAILED=0
await_all() {
  local i
  for i in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$i]}"; then FAILED=1; echo "fixture ${NAMES[$i]} failed" >&2; fi
  done
  PIDS=()
  NAMES=()
}


# ---- M2 subtitle and episode fixtures (design section 14) ----
# Text sources for embedded tracks live in a hidden folder, so sidecar discovery for
# subs_tracks.mkv only ever sees subs_tracks.zh-Hans.srt.
SRC="$OUT/.src"
mkdir -p "$SRC"

ass_file() { # ass_file <title> <line1> <line2> <sign>: bilingual ASS, Chinese at 45 and English at 27
  cat <<ASS
[Script Info]
ScriptType: v4.00+
Title: $1
PlayResX: 1280
PlayResY: 720
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,PingFang SC,45,&H00FFFFFF,&H000000FF,&H00000000,&H99000000,0,0,0,0,100,100,0,0,1,2.5,1.4,2,40,40,40,1
Style: EN,PingFang SC,27,&H00FFFFFF,&H000000FF,&H00000000,&H99000000,0,0,0,0,100,100,0,0,1,1.6,1,2,40,40,40,1
Style: Sign,PingFang SC,36,&H0000E5FF,&H000000FF,&H00202020,&H00000000,1,0,0,0,100,100,0,0,1,2,0,8,40,40,40,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,$2\N{\rEN}Don't look back. Keep walking.
Dialogue: 0,0:00:04.00,0:00:06.00,Default,,0,0,0,,$3\N{\rEN}We finally made it to the Northern Line.
Dialogue: 1,0:00:04.00,0:00:06.00,Sign,,0,0,0,,{\an8\pos(640,40)}$4
ASS
}

srt_file() { # srt_file <line1> <line2> [<line1b> <line2b>]: two events, optional second lines
  printf '1\n00:00:01,000 --> 00:00:03,000\n%s\n' "$1"
  if [ -n "${3:-}" ]; then printf '%s\n' "$3"; fi
  printf '\n2\n00:00:04,000 --> 00:00:06,000\n%s\n' "$2"
  if [ -n "${4:-}" ]; then printf '%s\n' "$4"; fi
}

EN1="Don't look back. Keep walking."
EN2="We finally made it to the Northern Line."

make_text_fixtures() {
  ass_file "简英双语" "别回头，继续往前走。" "我们终于到了北线。" "北线站" >"$SRC/zh_hans.ass"
  ass_file "繁英雙語" "別回頭，繼續往前走。" "我們終於到了北線。" "北線站" >"$SRC/zh_hant.ass"
  srt_file "$EN1" "$EN2" >"$SRC/en.srt"
  srt_file "[FOOTSTEPS] $EN1" "[TRAIN APPROACHING] $EN2" >"$SRC/en_sdh.srt"
  srt_file "别回头，继续往前走。" "我们终于到了北线。" "$EN1" "$EN2" | put subs_tracks.zh-Hans.srt

  # The charset trio carries the same text. It is Traditional so that Big5 can encode it.
  srt_file "別回頭，繼續往前走。" "我們終於到了北線。" "$EN1" "$EN2" | put subs_utf8.srt
  iconv -f UTF-8 -t GB18030 "$OUT/subs_utf8.srt" | put subs_gbk.srt
  iconv -f UTF-8 -t BIG5 "$OUT/subs_utf8.srt" | put subs_big5.cht.srt
  iconv -f GB18030 -t UTF-8 "$OUT/subs_gbk.srt" | cmp -s - "$OUT/subs_utf8.srt" || { echo "GB18030 round trip differs" >&2; return 1; }
  iconv -f BIG5 -t UTF-8 "$OUT/subs_big5.cht.srt" | cmp -s - "$OUT/subs_utf8.srt" || { echo "Big5 round trip differs" >&2; return 1; }

  # A positioned sign at the top and a bottom line, for the lift rule (section 8.5).
  cat <<'ASS' | put subs_ass_signs.ass
[Script Info]
ScriptType: v4.00+
Title: Signs and a bottom line
PlayResX: 1280
PlayResY: 720
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,PingFang SC,45,&H00FFFFFF,&H000000FF,&H00000000,&H99000000,0,0,0,0,100,100,0,0,1,2.5,1.4,2,40,40,40,1
Style: Sign,PingFang SC,36,&H0000E5FF,&H000000FF,&H00202020,&H00000000,1,0,0,0,100,100,0,0,1,2,0,8,40,40,40,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:06.00,Default,,0,0,0,,北线站到了。\NThis line sits at the bottom.
Dialogue: 1,0:00:01.00,0:00:06.00,Sign,,0,0,0,,{\an8\pos(640,60)}NORTHERN LINE 北线
ASS

  # PGS: two display sets with known rectangles, written by make-pgs.swift.
  if ! [ -s "$OUT/pgs_fixture.sup" ] || ! [ -s "$LOGS/pgs_rects.json" ]; then
    swift "$ROOT/scripts/make-pgs.swift" "$OUT/.partial-pgs_fixture.sup" "$LOGS/.partial-pgs_rects.json" \
      >"$LOGS/make-pgs.log" 2>&1 || { echo "FAILED make-pgs.swift, log: $LOGS/make-pgs.log" >&2; tail -20 "$LOGS/make-pgs.log" >&2; return 1; }
    mv "$OUT/.partial-pgs_fixture.sup" "$OUT/pgs_fixture.sup"
    mv "$LOGS/.partial-pgs_rects.json" "$LOGS/pgs_rects.json"
  fi

  # Episodes: four short files in natural order, an AppleDouble file and a text file.
  mkdir -p "$OUT/episodes"
  head -c 4096 /dev/zero | put episodes/._Northern.Line.S01E02.mkv
  printf 'Northern Line, season 1. Not a video.\n' | put episodes/notes.txt
}

echo "Generating fixtures into $OUT"
T0=$(date +%s)
make_text_fixtures || { echo "text fixtures failed" >&2; exit 1; }

# Seek-speed fixtures: recipes from the spike's hard.sh, realistic bitrates with noise.
start hevc10_1080p24.mkv \
  -f lavfi -i "testsrc2=s=1920x1080:r=24:d=60,noise=alls=10:allf=t" -f lavfi -i "sine=f=440:d=60" \
  -c:v libx265 -preset superfast -pix_fmt yuv420p10le \
  -x265-params "keyint=250:min-keyint=250:scenecut=0:bframes=8:open-gop=1:log-level=error" -b:v 20M \
  -c:a ac3 -ac 6 -b:a 448k
start av1_2160p60.mkv \
  -f lavfi -i "testsrc2=s=3840x2160:r=60:d=40,noise=alls=6:allf=t" -f lavfi -i "sine=f=440:d=40" \
  -c:v libsvtav1 -preset 9 -g 300 -b:v 25M -pix_fmt yuv420p -svtav1-params tune=0 \
  -c:a libopus -b:a 128k
start h264_1080p30.mp4 \
  -f lavfi -i "testsrc2=s=1920x1080:r=30:d=60,noise=alls=10:allf=t" -f lavfi -i "sine=f=440:d=60" \
  -c:v libx264 -preset veryfast -g 300 -keyint_min 300 -sc_threshold 0 -pix_fmt yuv420p -b:v 20M \
  -c:a aac -b:a 160k
start vp9_2160p60.webm \
  -f lavfi -i "testsrc2=s=3840x2160:r=60:d=40,noise=alls=6:allf=t" -f lavfi -i "sine=f=440:d=40" \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 -tile-columns 2 -g 300 -b:v 25M -pix_fmt yuv420p \
  -c:a libopus -b:a 128k

# A/V sync fixtures: black video with one white frame at every whole second, and a 50 ms
# 1 kHz beep starting at the same instants. 20 s each.
sync_video() { # fps
  echo "color=c=black:s=1280x720:r=$1:d=20,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='eq(mod(n,$1),0)'"
}
SYNC_AUDIO="aevalsrc='if(lt(mod(t,1),0.05),0.5*sin(2*PI*1000*t),0)|if(lt(mod(t,1),0.05),0.5*sin(2*PI*1000*t),0)':s=48000:d=20"
start sync_h264_aac.mp4 \
  -f lavfi -i "$(sync_video 30)" -f lavfi -i "$SYNC_AUDIO" \
  -c:v libx264 -preset veryfast -g 60 -keyint_min 60 -sc_threshold 0 -pix_fmt yuv420p -b:v 2M \
  -c:a aac -b:a 128k
start sync_hevc_opus.mkv \
  -f lavfi -i "$(sync_video 24)" -f lavfi -i "$SYNC_AUDIO" \
  -c:v libx265 -preset superfast -pix_fmt yuv420p -x265-params "keyint=48:min-keyint=48:scenecut=0:log-level=error" -b:v 2M \
  -c:a libopus -b:a 128k

# Small format-coverage fixtures, 2 s each.
start hdr10_hevc.mkv \
  -f lavfi -i "testsrc2=s=1920x1080:r=24:d=2,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv" \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le \
  -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:hdr10=1:hdr10-opt=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv
start annexb_h264.ts \
  -f lavfi -i "testsrc2=s=1280x720:r=30:d=2" -f lavfi -i "sine=f=440:d=2" \
  -c:v libx264 -preset veryfast -g 30 -pix_fmt yuv420p -c:a aac -b:a 128k
start mpeg4.avi \
  -f lavfi -i "testsrc2=s=640x480:r=25:d=2" -f lavfi -i "sine=f=440:d=2" \
  -c:v mpeg4 -vtag XVID -q:v 4 -g 50 -c:a libmp3lame -b:a 128k
start flv1.flv \
  -f lavfi -i "testsrc2=s=320x240:r=25:d=2" -f lavfi -i "sine=f=440:d=2:sample_rate=44100" \
  -c:v flv -q:v 4 -g 50 -c:a libmp3lame -ar 44100 -b:a 96k

# rot90: encode, then stream-copy with a 90 degree display matrix (the encoder would rotate pixels).
make_rot90() {
  local plain="$OUT/.partial-rot90-plain.mov"
  rm -f "$plain"
  ff -f lavfi -i "testsrc2=s=1280x720:r=30:d=2" -f lavfi -i "sine=f=440:d=2" \
    -c:v libx264 -preset veryfast -g 30 -pix_fmt yuv420p -c:a aac -b:a 128k -f mov "$plain" \
    >"$LOGS/rot90_h264.mov.log" 2>&1 || { rm -f "$plain"; echo "FAILED rot90_h264.mov" >&2; return 1; }
  local status=0
  encode rot90_h264.mov -display_rotation:v:0 90 -i "$plain" -map 0 -c copy || status=1
  rm -f "$plain"
  return "$status"
}
if [ -s "$OUT/rot90_h264.mov" ]; then echo "  rot90_h264.mov (kept)"; else make_rot90 & PIDS+=("$!"); NAMES+=(rot90_h264.mov); fi

# subs_tracks.mkv: 12 s 720p H.264, two 5.1 audio tracks and four subtitle tracks, events at
# 1 to 3 s and 4 to 6 s. -copyts keeps the subtitle times (ffmpeg would shift each input to 0).
start subs_tracks.mkv \
  -copyts \
  -f lavfi -i "testsrc2=s=1280x720:r=24:d=12" -f lavfi -i "sine=f=440:d=12" -f lavfi -i "sine=f=550:d=12" \
  -i "$SRC/zh_hans.ass" -i "$SRC/zh_hant.ass" -i "$SRC/en.srt" -i "$SRC/en_sdh.srt" \
  -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s -map 5:s -map 6:s \
  -c:v libx264 -preset veryfast -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p -b:v 2M \
  -c:a:0 eac3 -ac:a:0 6 -b:a:0 384k -c:a:1 aac -ac:a:1 6 -b:a:1 256k -c:s copy \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn \
  -metadata:s:s:0 language=zho -metadata:s:s:0 title=简英双语 \
  -metadata:s:s:1 language=zho -metadata:s:s:1 title=繁英雙語 \
  -metadata:s:s:2 language=eng -metadata:s:s:3 language=eng -metadata:s:s:3 title=SDH \
  -disposition:v:0 default -disposition:a:0 default -disposition:a:1 0 \
  -disposition:s:0 default -disposition:s:1 0 -disposition:s:2 0 -disposition:s:3 hearing_impaired

# subs_pgs.mkv: 8 s 1080p H.264 plus the PGS stream, copied as written.
start subs_pgs.mkv \
  -copyts \
  -f lavfi -i "testsrc2=s=1920x1080:r=24:d=8" -i "$OUT/pgs_fixture.sup" \
  -map 0:v -map 1:s -c:v libx264 -preset veryfast -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p -b:v 4M \
  -c:s copy -metadata:s:s:0 language=jpn

# Episodes: 3 s each, a different colour per file.
episode() { # episode <name> <colour>
  start "episodes/$1" \
    -f lavfi -i "color=c=$2:s=640x360:r=24:d=3" -f lavfi -i "sine=f=440:d=3" \
    -c:v libx264 -preset veryfast -g 24 -pix_fmt yuv420p -b:v 500k -c:a aac -b:a 96k
}
episode Northern.Line.S01E01.mkv 0x8B2E2E
episode Northern.Line.S01E02.mkv 0x2E6B8B
episode Northern.Line.S01E03.mkv 0x3C8B2E
episode Northern.Line.S01E10.mkv 0x8B7A2E

# >>> m3
# ---- M3 stage 1: HDR ramps, odd files and corpus bases (design sections 7.7, 7.8, 7.10) ----
mkdir -p "$OUT/hdr" "$OUT/odd" "$OUT/corpus"

# HDR ramps: one raw frame per transfer from make-ramp.py, looped to 2 s at 24 fps. The PQ and
# HLG masters are lossless HEVC carrying the HDR SEI; the published files are encoded from the
# decoded masters, so ffmpeg also writes the mastering metadata into each container.
MASTER_DISPLAY="G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
X265_LOSSLESS="log-level=error:lossless=1:keyint=24:min-keyint=24:scenecut=0:repeat-headers=1"
PQ_X265="colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:hdr10=1:master-display=$MASTER_DISPLAY:max-cll=1000,400"
HLG_X265="colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:range=limited"
RAMP_FRAMES=48

make_ramp_masters() {
  local transfer
  for transfer in pq hlg sdr; do
    python3 -I "$ROOT/scripts/make-ramp.py" "$transfer" "$SRC/ramp_$transfer.yuv" "$LOGS/ramps.json" || return 1
  done
  local raw10=(-f rawvideo -pix_fmt yuv420p10le -s 1920x1080 -framerate 24 -stream_loop -1)
  ff "${raw10[@]}" -i "$SRC/ramp_pq.yuv" -frames:v "$RAMP_FRAMES" \
    -vf "setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv" \
    -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params "$X265_LOSSLESS:$PQ_X265" \
    -f matroska "$SRC/pq_master.mkv" >"$LOGS/pq_master.log" 2>&1 || return 1
  ff "${raw10[@]}" -i "$SRC/ramp_hlg.yuv" -frames:v "$RAMP_FRAMES" \
    -vf "setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc:range=tv" \
    -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params "$X265_LOSSLESS:$HLG_X265" \
    -f matroska "$SRC/hlg_master.mkv" >"$LOGS/hlg_master.log" 2>&1 || return 1
}

# The AV1 ramp has its Matroska Colour element voided, so colour comes from the bitstream only.
make_av1_ramp() {
  local tmp="$OUT/hdr/.partial-pq_ramp_av1.mkv"
  rm -f "${tmp:?}"
  if ff -i "$SRC/pq_master.mkv" -map 0:v -c:v libsvtav1 -preset 6 -crf 4 -g 24 -pix_fmt yuv420p10le \
      -svtav1-params "tune=0:enable-hdr=1" -f matroska "$tmp" >"$LOGS/hdr_pq_ramp_av1.mkv.log" 2>&1 \
      && python3 -I "$ROOT/scripts/make-ramp.py" strip-mkv-colour "$tmp"; then
    mv "$tmp" "$OUT/hdr/pq_ramp_av1.mkv"
    echo "  hdr/pq_ramp_av1.mkv"
  else
    rm -f "${tmp:?}"
    echo "FAILED hdr/pq_ramp_av1.mkv, log: $LOGS/hdr_pq_ramp_av1.mkv.log" >&2
    return 1
  fi
}

if ! [ -s "$LOGS/ramps.json" ] || ! [ -s "$OUT/hdr/pq_ramp_hevc.mkv" ] || ! [ -s "$OUT/hdr/hlg_ramp_hevc.mkv" ] \
    || ! [ -s "$OUT/hdr/pq_ramp_av1.mkv" ] || ! [ -s "$OUT/hdr/pq_ramp_vp9.webm" ] || ! [ -s "$OUT/hdr/sdr_ramp_h264.mp4" ]; then
  rm -f "${LOGS:?}/ramps.json"
  make_ramp_masters || { echo "FAILED ramp masters, logs in $LOGS" >&2; FAILED=1; }
fi
if [ "$FAILED" = 0 ]; then
  start hdr/pq_ramp_hevc.mkv -i "$SRC/pq_master.mkv" -map 0:v \
    -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params "$X265_LOSSLESS:$PQ_X265"
  start hdr/hlg_ramp_hevc.mkv -i "$SRC/hlg_master.mkv" -map 0:v \
    -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params "$X265_LOSSLESS:$HLG_X265"
  start hdr/pq_ramp_vp9.webm -i "$SRC/pq_master.mkv" -map 0:v \
    -c:v libvpx-vp9 -lossless 1 -profile:v 2 -pix_fmt yuv420p10le -g 24 -row-mt 1 -deadline good -cpu-used 4
  start hdr/sdr_ramp_h264.mp4 \
    -f rawvideo -pix_fmt yuv420p -s 1920x1080 -framerate 24 -stream_loop -1 -i "$SRC/ramp_sdr.yuv" -frames:v "$RAMP_FRAMES" \
    -vf "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv" \
    -c:v libx264 -preset veryfast -crf 1 -profile:v high -g 24 -pix_fmt yuv420p \
    -x264-params "colorprim=bt709:transfer=bt709:colormatrix=bt709"
  if [ -s "$OUT/hdr/pq_ramp_av1.mkv" ]; then
    echo "  hdr/pq_ramp_av1.mkv (kept)"
  else
    make_av1_ramp &
    PIDS+=("$!")
    NAMES+=(hdr/pq_ramp_av1.mkv)
  fi
fi

# Odd but valid files and three non-media files (section 7.10), 3 s or less each.
[ -f "$OUT/odd/zero.mkv" ] || : >"$OUT/odd/zero.mkv"
printf 'This is a text file with a video file name.\nIt has no media in it.\n' | put odd/text.mp4
python3 -I -c 'import random, sys; sys.stdout.buffer.write(random.Random(1).randbytes(1 << 20))' | put odd/random.mkv
srt_file "$EN1" "$EN2" >"$SRC/many.srt"

ODD_VIDEO="testsrc2=s=1280x720:r=24:d=3"
ODD_AUDIO="sine=f=440:d=3"
start odd/prores.mov -f lavfi -i "testsrc2=s=640x360:r=24:d=2" -c:v prores_ks -profile:v 2 -pix_fmt yuv422p10le
# The cover is a one-frame source: -frames:v 1 would also end the audio after two packets.
start odd/audio_cover.mp3 -f lavfi -i "$ODD_AUDIO" -f lavfi -i "color=c=0x2E6B8B:s=320x320:r=1:d=1" \
  -map 0:a -map 1:v -c:a libmp3lame -b:a 128k -c:v mjpeg -disposition:v attached_pic -id3v2_version 3 \
  -metadata title="Northern Line Theme" -metadata:s:v comment="Cover (front)"
start odd/video_only.mp4 -f lavfi -i "$ODD_VIDEO" -c:v libx264 -preset veryfast -g 24 -pix_fmt yuv420p
start odd/one_frame.mkv -f lavfi -i "testsrc2=s=1280x720:r=24:d=1" -frames:v 1 -c:v libx264 -preset veryfast -pix_fmt yuv420p
start odd/tiny_16x16.mp4 -f lavfi -i "testsrc2=s=16x16:r=24:d=3" -f lavfi -i "$ODD_AUDIO" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -b:a 64k
# Odd dimensions need 4:4:4: 4:2:0 HEVC crops only in steps of two.
start odd/odd_1921x1081.mkv -f lavfi -i "testsrc2=s=1920x1080:r=24:d=2" -vf "format=yuv444p,scale=1921:1081" \
  -c:v libx265 -preset ultrafast -pix_fmt yuv444p -x265-params "log-level=error:keyint=24"
# MPEG-TS wraps its 33-bit 90 kHz clock at 95443.72 s; this offset (plus the muxer's 1.4 s
# delay) puts the wrap about 1.5 s into the file.
start odd/ts_wrap.ts -f lavfi -i "$ODD_VIDEO" -f lavfi -i "$ODD_AUDIO" \
  -c:v libx264 -preset veryfast -g 24 -pix_fmt yuv420p -c:a aac -b:a 96k -output_ts_offset 95440.8
start odd/vfr.mkv -f lavfi -i "$ODD_VIDEO" -f lavfi -i "$ODD_AUDIO" -vf "select='lt(n,24)+not(mod(n,3))'" -fps_mode vfr \
  -c:v libx264 -preset veryfast -g 24 -pix_fmt yuv420p -c:a aac -b:a 96k
start odd/intra_refresh.mp4 -f lavfi -i "$ODD_VIDEO" -f lavfi -i "$ODD_AUDIO" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -x264-params "intra-refresh=1:keyint=1000:min-keyint=1000:scenecut=0" \
  -c:a aac -b:a 96k
start odd/h264_422_10bit.mkv -f lavfi -i "testsrc2=s=1280x720:r=24:d=2" -f lavfi -i "sine=f=440:d=2" \
  -c:v libx264 -preset veryfast -pix_fmt yuv422p10le -c:a aac -b:a 96k
start odd/h264_444.mkv -f lavfi -i "testsrc2=s=1280x720:r=24:d=2" -f lavfi -i "sine=f=440:d=2" \
  -c:v libx264 -preset veryfast -pix_fmt yuv444p -profile:v high444 -c:a aac -b:a 96k
# Video starts 0.5 s after audio: an empty edit in the video track's edit list.
start odd/edit_list_offset.mp4 -itsoffset 0.5 -f lavfi -i "testsrc2=s=1280x720:r=24:d=2.5" -f lavfi -i "$ODD_AUDIO" \
  -map 0:v -map 1:a -c:v libx264 -preset veryfast -g 24 -pix_fmt yuv420p -c:a aac -b:a 96k

make_many_tracks() {
  local args=(-f lavfi -i "testsrc2=s=640x360:r=24:d=3" -f lavfi -i "$ODD_AUDIO" -i "$SRC/many.srt" -map 0:v)
  local languages=(eng jpn zho kor fra deu spa ita)
  local i
  for i in $(seq 0 31); do args+=(-map 1:a); done
  for i in $(seq 0 31); do args+=(-map 2:s); done
  args+=(-c:v libx264 -preset veryfast -g 24 -pix_fmt yuv420p -c:a aac -ac 1 -b:a 32k -c:s srt)
  for i in $(seq 0 31); do
    args+=("-metadata:s:a:$i" "language=${languages[$((i % 8))]}" "-metadata:s:a:$i" "title=Audio $((i + 1))")
    args+=("-metadata:s:s:$i" "language=${languages[$(((i + 3) % 8))]}" "-metadata:s:s:$i" "title=Subtitles $((i + 1))")
  done
  start odd/many_tracks.mkv "${args[@]}"
}
make_many_tracks

# Format changes mid-stream: two segments joined by the concat demuxer (timestamps continue).
make_joined_ts() { # make_joined_ts <name> <segment 1 args> -- <segment 2 args>
  local name="$1"
  shift
  local first=()
  while [ "$1" != -- ]; do first+=("$1"); shift; done
  shift
  local stem
  stem="$(basename "$name" .ts)"
  local a="$SRC/${stem}_a.ts" b="$SRC/${stem}_b.ts" list="$SRC/${stem}.txt"
  ff "${first[@]}" -f mpegts "$a" >"$LOGS/${stem}_a.log" 2>&1 \
    && ff "$@" -f mpegts "$b" >"$LOGS/${stem}_b.log" 2>&1 \
    && printf "file '%s'\nfile '%s'\n" "$a" "$b" >"$list" \
    && encode "$name" -f concat -safe 0 -i "$list" -map 0 -c copy
}
if [ -s "$OUT/odd/res_change.ts" ]; then
  echo "  odd/res_change.ts (kept)"
else
  make_joined_ts odd/res_change.ts \
    -f lavfi -i "testsrc2=s=1280x720:r=24:d=1.5" -f lavfi -i "sine=f=440:d=1.5" \
    -c:v libx264 -preset veryfast -g 12 -pix_fmt yuv420p -c:a aac -b:a 96k -- \
    -f lavfi -i "testsrc2=s=1920x1080:r=24:d=1.5" -f lavfi -i "sine=f=550:d=1.5" \
    -c:v libx264 -preset veryfast -g 12 -pix_fmt yuv420p -c:a aac -b:a 96k &
  PIDS+=("$!")
  NAMES+=(odd/res_change.ts)
fi
if [ -s "$OUT/odd/layout_change.ts" ]; then
  echo "  odd/layout_change.ts (kept)"
else
  make_joined_ts odd/layout_change.ts \
    -f lavfi -i "testsrc2=s=1280x720:r=24:d=1.5" -f lavfi -i "sine=f=440:d=1.5" \
    -c:v libx264 -preset veryfast -g 12 -pix_fmt yuv420p -c:a aac -ac 2 -b:a 128k -- \
    -f lavfi -i "testsrc2=s=1280x720:r=24:d=1.5" -f lavfi -i "sine=f=550:d=1.5" \
    -c:v libx264 -preset veryfast -g 12 -pix_fmt yuv420p -c:a aac -ac 6 -b:a 256k &
  PIDS+=("$!")
  NAMES+=(odd/layout_change.ts)
fi

# The 240-character name is too long for the log and temp names, so the file is encoded under
# a short name and renamed.
make_long_name() {
  local tmp="$OUT/odd/.partial-long-name.mkv"
  rm -f "${tmp:?}"
  if ff -f lavfi -i "testsrc2=s=1280x720:r=24:d=2" -f lavfi -i "sine=f=440:d=2" \
      -c:v libx264 -preset veryfast -g 24 -pix_fmt yuv420p -c:a aac -b:a 96k -f matroska "$tmp" >"$LOGS/odd_long_name.log" 2>&1; then
    mv "$tmp" "$OUT/odd/$LONG_NAME"
    echo "  odd/<240-character name>.mkv"
  else
    rm -f "${tmp:?}"
    echo "FAILED the long-name file, log: $LOGS/odd_long_name.log" >&2
    return 1
  fi
}
if [ -s "$OUT/odd/$LONG_NAME" ]; then
  echo "  odd/<240-character name>.mkv (kept)"
else
  make_long_name &
  PIDS+=("$!")
  NAMES+=(odd/long-name)
fi

# Corpus bases: 2 s, 640x360 with noise, keyframes every 0.5 s, one per container.
CORPUS_VIDEO="testsrc2=s=640x360:r=24:d=2,noise=alls=8:allf=t"
CORPUS_AUDIO="sine=f=440:d=2"
corpus_base() { # corpus_base <name> <codec args...>
  local name="$1"
  shift
  start "corpus/$name" -f lavfi -i "$CORPUS_VIDEO" -f lavfi -i "$CORPUS_AUDIO" "$@"
}
corpus_base h264_moov_end.mp4 -c:v libx264 -preset veryfast -g 12 -pix_fmt yuv420p -b:v 1500k -c:a aac -b:a 96k
corpus_base h264_faststart.mp4 -c:v libx264 -preset veryfast -g 12 -pix_fmt yuv420p -b:v 1500k -c:a aac -b:a 96k \
  -movflags +faststart
corpus_base hevc.mkv -c:v libx265 -preset ultrafast -pix_fmt yuv420p -b:v 1500k \
  -x265-params "log-level=error:keyint=12:min-keyint=12:scenecut=0" -c:a libopus -b:a 96k
corpus_base av1.mkv -c:v libsvtav1 -preset 10 -g 12 -pix_fmt yuv420p -b:v 1500k -c:a libopus -b:a 96k
corpus_base vp9.webm -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -g 12 -pix_fmt yuv420p -b:v 1500k -c:a libopus -b:a 96k
corpus_base h264.ts -c:v libx264 -preset veryfast -g 12 -pix_fmt yuv420p -b:v 1500k -c:a aac -b:a 96k
corpus_base mpeg4.avi -c:v mpeg4 -vtag XVID -q:v 5 -g 12 -c:a libmp3lame -b:a 96k
corpus_base flv1.flv -c:v flv -q:v 5 -g 12 -c:a libmp3lame -ar 44100 -b:a 96k
# <<< m3

await_all

# nocues: the HEVC file remuxed without Cues. Live mode skips the index (and the duration
# header, as in the spike's copy), so seeks must bisect.
if [ "$FAILED" = 0 ] && ! [ -s "$OUT/nocues_hevc.mkv" ]; then
  encode nocues_hevc.mkv -i "$OUT/hevc10_1080p24.mkv" -map 0 -c copy -live 1 || FAILED=1
fi

# >>> m3
# ---- M3 stage 2: files made from stage 1 outputs ----
if [ "$FAILED" = 0 ]; then
  for transfer in pq hlg; do
    if [ -s "$OUT/hdr/${transfer}_ramp_hevc.mp4" ]; then
      echo "  hdr/${transfer}_ramp_hevc.mp4 (kept)"
    else
      # moov after mdat (no faststart): make-dovi.py relies on it.
      encode "hdr/${transfer}_ramp_hevc.mp4" -i "$OUT/hdr/${transfer}_ramp_hevc.mkv" -map 0 -c copy -tag:v hvc1 || FAILED=1
    fi
  done
fi
make_dovi() { # make_dovi <name> <source> <make-dovi.py args...>
  local name="$1" source="$2"
  shift 2
  if [ -s "$OUT/$name" ]; then echo "  $name (kept)"; return 0; fi
  local log="$LOGS/${name//\//_}.log"
  if python3 -I "$ROOT/scripts/make-dovi.py" "$OUT/$source" "$OUT/$name" "$@" >"$log" 2>&1; then
    echo "  $name"
  else
    echo "FAILED $name, log: $log" >&2
    return 1
  fi
}
has_dovi() { # has_dovi <name> <profile> <compatibility>: ffprobe sees the record
  local report
  report="$("$FFPROBE" -v error -select_streams v:0 -show_streams -of json "$OUT/$1")" || return 1
  grep -Eq "\"dv_profile\": $2(,|\$)" <<<"$report" && grep -Eq "\"dv_bl_signal_compatibility_id\": $3(,|\$)" <<<"$report"
}
if [ "$FAILED" = 0 ]; then
  make_dovi hdr/dv81.mp4 hdr/pq_ramp_hevc.mp4 --profile 8 --level 6 --compatibility 1 || FAILED=1
  make_dovi hdr/dv84.mp4 hdr/hlg_ramp_hevc.mp4 --profile 8 --level 6 --compatibility 4 || FAILED=1
  make_dovi hdr/dv5.mp4 hdr/pq_ramp_hevc.mp4 --profile 5 --level 6 --compatibility 0 --sample-entry dvh1 || FAILED=1
fi
if [ "$FAILED" = 0 ]; then
  if [ -s "$OUT/hdr/dv81.mkv" ]; then
    echo "  hdr/dv81.mkv (kept)"
  else
    encode hdr/dv81.mkv -i "$OUT/hdr/dv81.mp4" -map 0 -c copy || FAILED=1
  fi
fi
if [ "$FAILED" = 0 ]; then
  for check in "dv81.mp4 8 1" "dv81.mkv 8 1" "dv84.mp4 8 4" "dv5.mp4 5 0"; do
    read -r name profile compatibility <<<"$check"
    if ! has_dovi "hdr/$name" "$profile" "$compatibility"; then
      echo "FAILED hdr/$name: ffprobe does not report Dolby Vision profile $profile compatibility $compatibility" >&2
      rm -f "${OUT:?}/hdr/${name:?}"
      FAILED=1
    fi
  done
fi

# Every ramp decodes (with Homebrew ffmpeg) to the codes make-ramp.py wrote: exact for the lossless
# HEVC and VP9 files, within 4 for AV1 and 2 for the SDR H.264.
verify_ramp() { # verify_ramp <name> <pq|hlg|sdr> <tolerance>
  local pixel_format=yuv420p10le
  if [ "$2" = sdr ]; then pixel_format=yuv420p; fi
  local frame="$SRC/verify-frame.yuv"
  if ff -i "$OUT/$1" -frames:v 1 -f rawvideo -pix_fmt "$pixel_format" "$frame" >"$LOGS/verify-ramp.log" 2>&1 \
      && python3 -I "$ROOT/scripts/make-ramp.py" verify "$2" "$frame" "$LOGS/ramps.json" "$3" >>"$LOGS/verify-ramp.log" 2>&1; then
    return 0
  fi
  echo "FAILED $1: decoded patch codes differ from logs/ramps.json" >&2
  cat "$LOGS/verify-ramp.log" >&2
  return 1
}
if [ "$FAILED" = 0 ]; then
  for check in "pq_ramp_hevc.mkv pq 0" "pq_ramp_hevc.mp4 pq 0" "hlg_ramp_hevc.mkv hlg 0" "hlg_ramp_hevc.mp4 hlg 0" \
      "pq_ramp_av1.mkv pq 4" "pq_ramp_vp9.webm pq 0" "sdr_ramp_h264.mp4 sdr 2" "dv81.mp4 pq 0" "dv81.mkv pq 0" "dv84.mp4 hlg 0"; do
    read -r name transfer tolerance <<<"$check"
    verify_ramp "hdr/$name" "$transfer" "$tolerance" || FAILED=1
  done
fi

# Corpus copies and manifest, written last by make-corpus.py.
if [ "$FAILED" = 0 ] && ! [ -s "$OUT/corpus/manifest.json" ]; then
  corpus_paths=()
  for base in "${CORPUS_BASES[@]}"; do corpus_paths+=("$OUT/corpus/$base"); done
  if python3 -I "$ROOT/scripts/make-corpus.py" --ffprobe "$FFPROBE" "$OUT/corpus" "${corpus_paths[@]}" >"$LOGS/make-corpus.log" 2>&1; then
    echo "  corpus/ ($(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["files"]))' "$OUT/corpus/manifest.json") files)"
  else
    echo "FAILED make-corpus.py, log: $LOGS/make-corpus.log" >&2
    tail -20 "$LOGS/make-corpus.log" >&2
    FAILED=1
  fi
fi
if [ "$FAILED" = 0 ]; then
  corpus_kb="$(du -sk "$OUT/corpus" | cut -f1)"
  if [ "$corpus_kb" -gt 153600 ]; then
    echo "corpus/ is $((corpus_kb / 1024)) MB, over the 150 MB budget" >&2
    FAILED=1
  fi
fi
# <<< m3

# >>> m3-color
# ---- SDR colour bars (AC-M3-8) ----
# One RGB colour per patch: 75% bars, greys, 100% primaries and secondaries, six Macbeth patches.
BAR_COLOURS=(
  BFBFBF BFBF00 00BFBF 00BF00 BF00BF BF0000
  0000BF 000000 202020 404040 808080 FFFFFF
  FF0000 00FF00 0000FF 00FFFF FF00FF FFFF00
  C29682 735244 627A9D 576C43 8580B1 67BDAA
)
bars_graph() { # bars_graph <width> <height> <matrix>: 6 x 4 flat RGB patches scaled to exactly <width> x <height>, converted to 4:2:0
  local cell_w=$(($1 / 6)) cell_h=$(($2 / 4)) graph="" row column index
  for index in "${!BAR_COLOURS[@]}"; do
    graph+="color=c=0x${BAR_COLOURS[$index]}:s=${cell_w}x${cell_h}:r=24:d=2,format=rgb24[c$index];"
  done
  for row in 0 1 2 3; do
    for column in 0 1 2 3 4 5; do graph+="[c$((row * 6 + column))]"; done
    graph+="hstack=inputs=6[r$row];"
  done
  graph+="[r0][r1][r2][r3]vstack=inputs=4,scale=w=$1:h=$2:out_color_matrix=$3:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p"
  printf '%s' "$graph"
}
BARS_X264=(-c:v libx264 -preset veryfast -crf 1 -profile:v high -g 24 -pix_fmt yuv420p)
mkdir -p "$OUT/sdr"
start sdr/bars709_h264.mp4 -filter_complex \
  "$(bars_graph 1920 1080 bt709),setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv" \
  "${BARS_X264[@]}" -x264-params "colorprim=bt709:transfer=bt709:colormatrix=bt709"
start sdr/bars709_untagged_h264.mp4 -filter_complex \
  "$(bars_graph 1920 1080 bt709),setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown:range=tv" \
  "${BARS_X264[@]}"
start sdr/bars601_sd_h264.mp4 -filter_complex \
  "$(bars_graph 704 480 bt601),setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown:range=tv" \
  "${BARS_X264[@]}"
await_all
# The untagged files must carry no colour description in the stream or the container.
for name in sdr/bars709_untagged_h264.mp4 sdr/bars601_sd_h264.mp4; do
  [ -s "$OUT/$name" ] || continue
  if "$FFPROBE" -v error -select_streams v:0 -show_entries stream=color_space,color_primaries,color_transfer \
      -of default=noprint_wrappers=1 "$OUT/$name" | grep -Ev '=(unknown)?$' | grep -q .; then
    echo "FAILED $name: it carries a colour description" >&2
    rm -f "${OUT:?}/${name:?}"
    FAILED=1
  fi
done
# <<< m3-color

# >>> m3-dovi
# ---- Dolby Vision with real RPUs (AC-M3-3 support, section 7.8) ----
# A generator only: compiled against Homebrew's FFmpeg headers and libraries into .src, never
# linked into Reel. libx265 requires VBV settings for Dolby Vision.
make_dovi_rpu() { # make_dovi_rpu <name> <source> <81|84|5> <x265-params>
  local name="$1" log="$LOGS/${1//\//_}.log" tmp="$OUT/hdr/.partial-$(basename "$1")"
  if [ -s "$OUT/$name" ]; then echo "  $name (kept)"; return 0; fi
  rm -f "${tmp:?}"
  if "$SRC/make-dovi-rpu" "$OUT/$2" "$tmp" "$3" "$4" >"$log" 2>&1; then
    mv "$tmp" "$OUT/$name"
    echo "  $name"
  else
    rm -f "${tmp:?}"
    echo "FAILED $name, log: $log" >&2
    return 1
  fi
}
if [ "$FAILED" = 0 ]; then
  BREW_PREFIX="$(cd "$(dirname "$FFMPEG")/.." && pwd)"
  DOVI_X265="$X265_LOSSLESS:vbv-maxrate=160000:vbv-bufsize=160000"
  if ! xcrun clang -O1 -Wall -I"$BREW_PREFIX/include" "$ROOT/scripts/make-dovi-rpu.c" -o "$SRC/make-dovi-rpu" \
      -L"$BREW_PREFIX/lib" -lavformat -lavcodec -lavutil >"$LOGS/make-dovi-rpu-build.log" 2>&1; then
    echo "FAILED make-dovi-rpu build, log: $LOGS/make-dovi-rpu-build.log" >&2
    FAILED=1
  else
    make_dovi_rpu hdr/dv81_rpu.mp4 hdr/pq_ramp_hevc.mkv 81 "$DOVI_X265:$PQ_X265" || FAILED=1
    make_dovi_rpu hdr/dv84_rpu.mp4 hdr/hlg_ramp_hevc.mkv 84 "$DOVI_X265:$HLG_X265" || FAILED=1
    make_dovi_rpu hdr/dv5_rpu.mp4 hdr/pq_ramp_hevc.mkv 5 "$DOVI_X265:range=full" || FAILED=1
  fi
fi
if [ "$FAILED" = 0 ]; then
  for check in "dv81_rpu.mp4 8 1" "dv84_rpu.mp4 8 4" "dv5_rpu.mp4 5 0"; do
    read -r name profile compatibility <<<"$check"
    if ! has_dovi "hdr/$name" "$profile" "$compatibility"; then
      echo "FAILED hdr/$name: ffprobe does not report Dolby Vision profile $profile compatibility $compatibility" >&2
      FAILED=1
    elif ! grep -q '"Dolby Vision RPU Data"' <<<"$("$FFPROBE" -v error -select_streams v:0 -show_frames \
        -read_intervals '%+#1' -of json "$OUT/hdr/$name")"; then
      echo "FAILED hdr/$name: no RPU on the first frame" >&2
      FAILED=1
    fi
  done
  for check in "dv81_rpu.mp4 pq 0" "dv84_rpu.mp4 hlg 0"; do
    read -r name transfer tolerance <<<"$check"
    verify_ramp "hdr/$name" "$transfer" "$tolerance" || FAILED=1
  done
fi
# <<< m3-dovi

# >>> m3-reorder
# ---- Decode-order pts (MP4 without ctts) ----
# A luma ramp with a hard cut at frame 40, so frames in the wrong order show as a luma step back.
# The HEVC file has open GOPs and a scene cut, so the cut is a CRA with RASL leading pictures.
REORDER_VIDEO="color=c=gray:s=320x240:r=24:d=4,format=yuv420p,geq=lum='if(lt(N\,40)\,24+N*2\,150+(N-40)*1.5)':cb=128:cr=128"
# Renames the one ctts box under moov/trak/mdia/minf/stbl to free (same size, ignored by readers).
DROP_CTTS='
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
def walk(start, end):
    found = 0
    while start + 8 <= end:
        size, kind = struct.unpack(">I4s", data[start:start + 8])
        if size == 1:
            size = struct.unpack(">Q", data[start + 8:start + 16])[0]
        elif size == 0:
            size = end - start
        if size < 8:
            break
        if kind == b"ctts":
            data[start + 4:start + 8] = b"free"
            found += 1
        elif kind in (b"moov", b"trak", b"mdia", b"minf", b"stbl"):
            found += walk(start + 8, start + size)
        start += size
    return found
if walk(0, len(data)) != 1:
    sys.exit("expected exactly one ctts box")
sys.stdout.buffer.write(data)
'
make_no_ctts() { # make_no_ctts <name> <video codec args...>
  local name="$1"
  shift
  if [ -s "$OUT/$name" ]; then echo "  $name (kept)"; return 0; fi
  local log="$LOGS/${name//\//_}.log" with_ctts="$SRC/$(basename "$name" .mp4)_ctts.mp4"
  if ff -f lavfi -i "$REORDER_VIDEO" "$@" -an -use_editlist 0 -f mp4 "$with_ctts" >"$log" 2>&1 \
      && python3 -I -c "$DROP_CTTS" "$with_ctts" 2>>"$log" | put "$name" \
      && [ -z "$("$FFPROBE" -v error -select_streams v:0 -show_entries packet=pts,dts -of csv=p=0 "$OUT/$name" | awk -F, '$1 != $2')" ]; then
    echo "  $name"
  else
    rm -f "${OUT:?}/${name:?}"
    echo "FAILED $name, log: $log" >&2
    return 1
  fi
}
if [ "$FAILED" = 0 ]; then
  make_no_ctts reorder/hevc_open_gop_no_ctts.mp4 -c:v libx265 -preset ultrafast -tag:v hvc1 \
    -x265-params "log-level=error:keyint=48:min-keyint=1:scenecut=40:bframes=4:b-adapt=0:open-gop=1:qp=10" || FAILED=1
  make_no_ctts reorder/h264_no_ctts.mp4 -c:v libx264 -preset veryfast -qp 10 \
    -x264-params "keyint=48:min-keyint=1:scenecut=40:bframes=3:b-pyramid=normal:open-gop=1" || FAILED=1
fi
if [ "$FAILED" = 0 ]; then
  if [ -s "$OUT/reorder/hevc_no_ctts_remux.mkv" ]; then
    echo "  reorder/hevc_no_ctts_remux.mkv (kept)"
  else
    encode reorder/hevc_no_ctts_remux.mkv -i "$OUT/reorder/hevc_open_gop_no_ctts.mp4" -c copy || FAILED=1
  fi
  if [ -s "$OUT/reorder/h264_bframes.avi" ]; then
    echo "  reorder/h264_bframes.avi (kept)"
  else
    encode reorder/h264_bframes.avi -f lavfi -i "$REORDER_VIDEO" -c:v libx264 -preset veryfast -qp 10 \
      -x264-params "keyint=48:min-keyint=1:scenecut=40:bframes=3:b-pyramid=normal" || FAILED=1
  fi
  if [ -s "$OUT/reorder/mpeg4_bframes.avi" ]; then
    echo "  reorder/mpeg4_bframes.avi (kept)"
  else
    encode reorder/mpeg4_bframes.avi -f lavfi -i "$REORDER_VIDEO" -c:v mpeg4 -vtag XVID -q:v 2 -bf 2 -g 12 -sc_threshold 1000000000 || FAILED=1
  fi
  if [ -s "$OUT/reorder/raw_bframes.h264" ]; then
    echo "  reorder/raw_bframes.h264 (kept)"
  else
    encode reorder/raw_bframes.h264 -f lavfi -i "$REORDER_VIDEO" -c:v libx264 -preset veryfast -qp 10 \
      -x264-params "keyint=48:min-keyint=1:scenecut=40:bframes=3:b-pyramid=normal" || FAILED=1
  fi
  if [ -s "$OUT/reorder/raw_open_gop.hevc" ]; then
    echo "  reorder/raw_open_gop.hevc (kept)"
  else
    encode reorder/raw_open_gop.hevc -f lavfi -i "$REORDER_VIDEO" -c:v libx265 -preset ultrafast \
      -x265-params "log-level=error:keyint=48:min-keyint=1:scenecut=40:bframes=4:b-adapt=0:open-gop=1:qp=10" || FAILED=1
  fi
fi
# <<< m3-reorder

# >>> m3-mpeg2
# ---- MPEG-2 (DVD and TV) ----
# Two sync files as for the M1 ones (a white frame and a 50 ms beep at every whole second, 20 s,
# PAL 25 fps): a program stream with MP2 audio, and a DVD .vob with interlaced coding and AC3 in a
# private stream. The ramp has a rising luma per frame and B-frames, for frame order and seeks.
MPEG2_SYNC_VIDEO="color=c=black:s=720x576:r=25:d=20,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='eq(mod(n,25),0)'"
MPEG2_RAMP="color=c=gray:s=720x480:r=30000/1001:d=4,format=yuv420p,geq=lum='20+N*1.5':cb=128:cr=128"
MPEG2_VIDEO=(-c:v mpeg2video -b:v 6M -maxrate 9M -bufsize 1835k -bf 2 -g 12)
if [ "$FAILED" = 0 ]; then
  start mpeg2/sync_mpeg2_mp2.mpg -f lavfi -i "$MPEG2_SYNC_VIDEO" -f lavfi -i "$SYNC_AUDIO" \
    "${MPEG2_VIDEO[@]}" -c:a mp2 -b:a 224k
  start mpeg2/sync_mpeg2_ac3.vob -f lavfi -i "$MPEG2_SYNC_VIDEO" -f lavfi -i "$SYNC_AUDIO" \
    "${MPEG2_VIDEO[@]}" -flags +ilme+ildct -c:a ac3 -b:a 192k
  start mpeg2/ramp_mpeg2.ts -f lavfi -i "$MPEG2_RAMP" -f lavfi -i "sine=f=440:d=4" \
    -c:v mpeg2video -q:v 2 -bf 2 -g 15 -sc_threshold 1000000000 -c:a mp2 -b:a 192k
  # 60 fields a second from a moving 60p source, woven top field first into 30i frames.
  INTERLACED_SOURCE="testsrc2=s=720x480:r=60000/1001:d=3,tinterlace=mode=interleave_top,setfield=tff"
  start interlaced/mpeg2_tff.ts -f lavfi -i "$INTERLACED_SOURCE" \
    -c:v mpeg2video -q:v 2 -bf 2 -g 15 -flags +ilme+ildct -an
  start interlaced/h264_mbaff_tff.ts -f lavfi -i "$INTERLACED_SOURCE" \
    -c:v libx264 -preset veryfast -qp 12 -x264-params "interlaced=1:tff=1" -pix_fmt yuv420p -an
  await_all
fi
# <<< m3-mpeg2

if [ "$FAILED" != 0 ]; then
  echo "fixture generation failed" >&2
  exit 1
fi
all_present || { echo "some fixtures are missing" >&2; exit 1; }
touch "$STAMP"
echo "Fixtures ready in $OUT ($(( $(date +%s) - T0 )) s)"
