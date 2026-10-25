#!/usr/bin/env bash
# Generates Reel's test media (design section 14) with Homebrew ffmpeg, used only as a generator.
# Every file comes from lavfi sources (testsrc2 plus temporal noise, colour, sine, aevalsrc),
# subtitle text written by this script and a PGS stream from scripts/make-pgs.swift; nothing is
# read from the user's media.
#
# Usage: scripts/fixtures.sh            output: ${REEL_FIXTURES:-<repo>/build/fixtures}
# Env:   FORCE=1 regenerates everything.
#
# The stamp file .fixtures-<script hash> is written last; when it matches and every file is
# present the script exits at once. Encodes run in parallel, tracked and awaited by PID.
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
for encoder in libx265 libx264 libsvtav1 libvpx-vp9 libopus ac3 aac mpeg4 flv libmp3lame; do
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

SCRIPT_HASH="$(shasum -a 256 "${BASH_SOURCE[0]}" | cut -c1-16)"
STAMP="$OUT/.fixtures-$SCRIPT_HASH"

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
  for name in "${FIXTURES[@]}"; do
    [ -s "$OUT/$name" ] || return 1
  done
}

if [ -f "$STAMP" ] && [ "${FORCE:-0}" != 1 ] && all_present; then
  echo "Fixtures up to date in $OUT ($(basename "$STAMP")). Set FORCE=1 to regenerate."
  exit 0
fi

# A different script version invalidates every file; a rerun of an interrupted run of the
# same version keeps what it finished (each file is renamed into place only when complete).
VERSION_FILE="$OUT/.version"
if [ "${FORCE:-0}" = 1 ] || [ "$(cat "$VERSION_FILE" 2>/dev/null || true)" != "$SCRIPT_HASH" ]; then
  for name in "${FIXTURES[@]}"; do rm -f "$OUT/$name"; done
fi
rm -f "$OUT"/.fixtures-*
echo "$SCRIPT_HASH" >"$VERSION_FILE"

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
    avi) echo avi ;;
    flv) echo flv ;;
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

await_all

# nocues: the HEVC file remuxed without Cues. Live mode skips the index (and the duration
# header, as in the spike's copy), so seeks must bisect.
if [ "$FAILED" = 0 ] && ! [ -s "$OUT/nocues_hevc.mkv" ]; then
  encode nocues_hevc.mkv -i "$OUT/hevc10_1080p24.mkv" -map 0 -c copy -live 1 || FAILED=1
fi

if [ "$FAILED" != 0 ]; then
  echo "fixture generation failed" >&2
  exit 1
fi
all_present || { echo "some fixtures are missing" >&2; exit 1; }
touch "$STAMP"
echo "Fixtures ready in $OUT ($(( $(date +%s) - T0 )) s)"
