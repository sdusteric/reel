#!/usr/bin/env bash
# Builds minimal static LGPL FFmpeg + libass (CoreText) for arm64 macOS.
# No Homebrew libraries are linked. Homebrew only supplies build tools
# (meson, ninja, nasm, pkg-config, autotools) found on PATH.
#
# Usage: scripts/deps.sh
# Layout: tarballs in vendor/src, build trees in vendor/build, install prefix vendor/prefix.
#         Headers are synced into Sources/CReelDeps/include (gitignored).
# Env:   FORCE=1 rebuilds even when the stamp matches.
#        MACOSX_DEPLOYMENT_TARGET (default 14.0, the verified value for the C libraries)
#        JOBS (default: hw.ncpu)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$ROOT/vendor/prefix"
SRC="$ROOT/vendor/src"
BUILD="$ROOT/vendor/build"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

FFMPEG_VER=9.0.2
FFMPEG_SHA=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
LIBASS_VER=0.17.5
LIBASS_SHA=2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
HARFBUZZ_VER=15.0.0
HARFBUZZ_SHA=968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df
FRIBIDI_VER=1.0.17
FRIBIDI_SHA=6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2
FREETYPE_VER=2.15.0
FREETYPE_SHA=87c7f1f8699b91e89f773f7dcfa505b044e1dae67f62a55d4e29c3afdcac4fb8
DAV1D_VER=1.5.4
DAV1D_SHA=2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011

mkdir -p "$SRC" "$BUILD" "$PREFIX"

# Use Xcode's toolchain and keep Homebrew headers and libraries out of the build.
CC="$(xcrun -f clang)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC SDKROOT
export CFLAGS="-arch arm64 -O2 -fPIC -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -isysroot $SDKROOT"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -isysroot $SDKROOT"
export CPPFLAGS="-I$PREFIX/include"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

fetch() { # name url file sha
  local file="$SRC/$3"
  if [ ! -f "$file" ]; then echo "==> download $3"; curl -fsSL -o "$file.part" "$2"; mv "$file.part" "$file"; fi
  local got; got="$(shasum -a 256 "$file" | awk '{print $1}')"
  echo "sha256 $3 $got"
  if [ "$got" != "$4" ]; then echo "SHA256 MISMATCH for $3 (expected $4)" >&2; exit 1; fi
}
unpack() { # file dir
  rm -rf "${BUILD:?}/$2"; mkdir -p "$BUILD/$2"
  tar -xf "$SRC/$1" -C "$BUILD/$2" --strip-components=1
}
step() { echo; echo "=== $1 ($(date +%H:%M:%S)) ==="; }

# Skip the rebuild when PREFIX was already built by this exact script (FORCE=1 overrides).
# Patches applied to the FFmpeg source (scripts/patches): the VP9 tile check of section 7.10.
FFMPEG_PATCHES=("$ROOT/scripts/patches/ffmpeg-vp9-tile-check.patch")
SCRIPT_HASH="$(cat "${BASH_SOURCE[0]}" "${FFMPEG_PATCHES[@]}" | shasum -a 256 | cut -c1-16)"
STAMP="$PREFIX/.deps-stamp-$SCRIPT_HASH"
HEADERS_DEST="$ROOT/Sources/CReelDeps/include"
HEADER_DIRS=(libavcodec libavformat libavutil libswscale libswresample ass freetype2 harfbuzz fribidi dav1d)

sync_headers() {
  # Swift's clang importer also searches /opt/homebrew/include, whose FFmpeg headers have a
  # different struct layout. The headers Swift sees must sit in the C target's public include
  # dir (next to CReelDeps.h), not behind a headerSearchPath.
  mkdir -p "$HEADERS_DEST"
  local d
  for d in "${HEADER_DIRS[@]}"; do
    if [ ! -d "$PREFIX/include/$d" ]; then echo "missing $PREFIX/include/$d" >&2; exit 1; fi
    mkdir -p "$HEADERS_DEST/$d"
    rsync -a --delete "$PREFIX/include/$d/" "$HEADERS_DEST/$d/"
  done
  echo "headers synced to $HEADERS_DEST"
}

check_license() {
  # The FFmpeg build must stay LGPL: never --enable-gpl, --enable-nonfree or --enable-version3.
  local cfg="$BUILD/ffmpeg/config.h"
  if [ -f "$cfg" ]; then
    if grep -E 'FFMPEG_CONFIGURATION.*--enable-(gpl|nonfree|version3)' "$cfg" >/dev/null; then
      echo "FFmpeg configuration enables a non-LGPL option" >&2; exit 1
    fi
    grep -q 'FFMPEG_LICENSE "LGPL version 2.1 or later"' "$cfg" || { echo "FFmpeg license is not LGPL 2.1+" >&2; exit 1; }
    echo "license: LGPL version 2.1 or later"
  fi
}

if [ -f "$STAMP" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "Already built ($STAMP). Set FORCE=1 to rebuild."; sync_headers; exit 0
fi

for tool in meson ninja nasm pkg-config make; do
  command -v "$tool" >/dev/null || { echo "missing build tool: $tool" >&2; exit 1; }
done

T0=$(date +%s)

fetch ffmpeg  "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz" "ffmpeg-$FFMPEG_VER.tar.xz" $FFMPEG_SHA
fetch libass  "https://github.com/libass/libass/releases/download/$LIBASS_VER/libass-$LIBASS_VER.tar.xz" "libass-$LIBASS_VER.tar.xz" $LIBASS_SHA
fetch harfbuzz "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VER/harfbuzz-$HARFBUZZ_VER.tar.xz" "harfbuzz-$HARFBUZZ_VER.tar.xz" $HARFBUZZ_SHA
fetch fribidi "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VER/fribidi-$FRIBIDI_VER.tar.xz" "fribidi-$FRIBIDI_VER.tar.xz" $FRIBIDI_SHA
fetch freetype "https://github.com/freetype/freetype/archive/refs/tags/VER-${FREETYPE_VER//./-}.tar.gz" "freetype-$FREETYPE_VER.tar.gz" $FREETYPE_SHA
fetch dav1d   "https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VER/dav1d-$DAV1D_VER.tar.bz2" "dav1d-$DAV1D_VER.tar.bz2" $DAV1D_SHA

# A fresh prefix: stale libraries from an older pin must not survive a rebuild.
for sub in include lib share; do rm -rf "${PREFIX:?}/$sub"; done
rm -f "$PREFIX"/.deps-stamp-*

# Always cross-compile for arm64 through an explicit meson cross file. meson here may be an
# x86_64 binary under Rosetta and would otherwise detect an x86_64 host and enable x86 asm.
MESON_CROSS="$BUILD/arm64-macos.ini"
cat > "$MESON_CROSS" <<INI
[binaries]
c = '$CC'
cpp = '$(xcrun -f clang++)'
ar = '$(xcrun -f ar)'
strip = '$(xcrun -f strip)'
ranlib = '$(xcrun -f ranlib)'
pkgconfig = '$(command -v pkg-config)'
[built-in options]
c_args = ['-arch', 'arm64', '-O2', '-fPIC', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET', '-isysroot', '$SDKROOT']
cpp_args = ['-arch', 'arm64', '-O2', '-fPIC', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET', '-isysroot', '$SDKROOT']
c_link_args = ['-arch', 'arm64', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET', '-isysroot', '$SDKROOT']
cpp_link_args = ['-arch', 'arm64', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET', '-isysroot', '$SDKROOT']
[properties]
needs_exe_wrapper = false
pkg_config_libdir = '$PREFIX/lib/pkgconfig'
[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
INI
MESON_COMMON=(--cross-file "$MESON_CROSS" --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static -Db_lto=false)

step dav1d
unpack "dav1d-$DAV1D_VER.tar.bz2" dav1d
( cd "$BUILD/dav1d" && meson setup out "${MESON_COMMON[@]}" \
    -Denable_tools=false -Denable_tests=false -Denable_examples=false -Dxxhash_muxer=disabled \
  && ninja -C out -j"$JOBS" && ninja -C out install )

step freetype
unpack "freetype-$FREETYPE_VER.tar.gz" freetype
( cd "$BUILD/freetype" && meson setup out "${MESON_COMMON[@]}" \
    -Dzlib=system -Dbzip2=disabled -Dpng=disabled -Dharfbuzz=disabled -Dbrotli=disabled -Dhvf=disabled -Dmmap=enabled \
  && ninja -C out -j"$JOBS" && ninja -C out install )

step fribidi
unpack "fribidi-$FRIBIDI_VER.tar.xz" fribidi
( cd "$BUILD/fribidi" && meson setup out "${MESON_COMMON[@]}" \
    -Ddocs=false -Dbin=false -Dtests=false \
  && ninja -C out -j"$JOBS" && ninja -C out install )

step harfbuzz
unpack "harfbuzz-$HARFBUZZ_VER.tar.xz" harfbuzz
( cd "$BUILD/harfbuzz" && meson setup out "${MESON_COMMON[@]}" \
    -Dfreetype=enabled -Dcoretext=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
    -Dicu=disabled -Dgraphite=disabled -Dgraphite2=disabled -Dchafa=disabled \
    -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dbenchmark=disabled -Dutilities=disabled \
  && ninja -C out -j"$JOBS" && ninja -C out install )

step libass
unpack "libass-$LIBASS_VER.tar.xz" libass
( cd "$BUILD/libass" && ./configure --prefix="$PREFIX" --enable-static --disable-shared \
    --disable-fontconfig --enable-coretext --disable-directwrite --disable-libunibreak \
    --disable-require-system-font-provider \
  && make -j"$JOBS" && make install )

step ffmpeg
unpack "ffmpeg-$FFMPEG_VER.tar.xz" ffmpeg
for patch in "${FFMPEG_PATCHES[@]}"; do
  echo "patch $(basename "$patch")"
  patch -d "$BUILD/ffmpeg" -p1 --forward --silent < "$patch"
done
( cd "$BUILD/ffmpeg" && ./configure \
    --prefix="$PREFIX" --arch=arm64 --target-os=darwin \
    --cc="$CC" --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
    --enable-static --disable-shared --disable-programs --disable-avdevice --disable-avfilter --disable-doc --disable-debug \
    --disable-autodetect --disable-network --disable-xlib --disable-sdl2 \
    --enable-iconv --enable-zlib --enable-bzlib --pkg-config-flags=--static \
    --disable-everything \
    --enable-avcodec --enable-avformat --enable-avutil --enable-swresample --enable-swscale \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-protocol=file \
    --enable-demuxer=matroska,mov,mpegts,flv,avi,ogg,wav,mp3,aac,flac,srt,ass,webvtt,concat \
    --enable-parser=h264,hevc,vp9,av1,aac,ac3,opus,mpegaudio,flac,dca \
    --enable-decoder=h264,hevc,vp9,av1,libdav1d,mpeg4,msmpeg4v3,mpeg2video,vc1,flv \
    --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,vp9_videotoolbox,av1_videotoolbox,mpeg2_videotoolbox,mpeg4_videotoolbox \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,vp9_superframe,av1_frame_merge,extract_extradata \
    --enable-decoder=aac,ac3,eac3,dca,truehd,mlp,flac,opus,vorbis,mp3,mp3float,alac \
    --enable-decoder='pcm_*' \
    --enable-decoder=ass,ssa,subrip,srt,webvtt,mov_text,pgssub,dvdsub \
    --enable-libdav1d \
  && make -j"$JOBS" && make install )

check_license
touch "$STAMP"
sync_headers
T1=$(date +%s)
echo
echo "Build complete in $((T1 - T0)) s. Prefix: $PREFIX"
ls -la "$PREFIX"/lib/*.a
