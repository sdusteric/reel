# Reel

A macOS video player for one person, replacing IINA on this Mac. Own engine: FFmpeg demux and
audio decode, direct VideoToolbox into `AVSampleBufferDisplayLayer`, `AVSampleBufferRenderSynchronizer`
as the clock. The design doc is the source of truth: `docs/superpowers/specs/2026-10-24-reel-design.md`.

## Commands

```sh
scripts/deps.sh                 # static LGPL FFmpeg 9.0.2 (+ scripts/patches) + libass into vendor/prefix (stamped, about 60 s cold)
scripts/fixtures.sh             # generated test media into ${REEL_FIXTURES:-build/fixtures} (stamped, about 50 s)
swift build --scratch-path "$TMPDIR/reel-<task>"
swift test --scratch-path "$TMPDIR/reel-<task>" --filter <Suite>
swiftlint lint --strict
REEL_SCRATCH="$TMPDIR/reel-check" scripts/check.sh   # every gate
scripts/shots.sh                # 28 scenarios x light/dark background screenshots into build/shots
REEL_SCRATCH="$TMPDIR/reel-accept" scripts/accept.sh offline   # M1 criteria, then the M2 and M3 groups
REEL_SCRATCH="$TMPDIR/reel-accept" scripts/accept.sh m3        # only AC-M3-1 to AC-M3-10
scripts/release.sh [--notes <file.md>] [--dry-run <dir>]   # check.sh, release bundle, app-updates publish.sh
```

`check.sh` gates, in order: deps, fixtures, build, test, lint, license, `av-sync` (the H.264, HEVC
and two MPEG-2 sync fixtures, at most 20 ms sequentially and after 10 seeks), `soak-smoke` (12 corpus files through
`reelctl soak`: no crash, hang or manifest mismatch), no-sparkle, bundle, codesign, plist, sparkle,
requirement, dashes.

`reelctl` (headless, always with `REEL_HOME` set to a temp dir; `swift build -c release` puts it in
`$SCRATCH/release/reelctl`). `probe`, `decode-bench`, `seek-bench` and `av-sync` are the M1 tools;
the M2 ones:

```sh
reelctl subs <file> [--no-external] [--at s] [--size WxH] [--frames N] [--dump-text] --json   # track choice, charset, ink, bbox, fonts, render_ms
reelctl thumbs <file> [--runs N] [--fresh-cache] [--cold] --json   # count, setup_ms, per_thumb_ms, image widths, cache_reload_ms
reelctl episodes <file> --json                            # folder order, index, next and previous
reelctl seek-bench <file> [--runs N] [--with-thumbs] --json   # M1 seek thresholds, VP9 hand-offs; --with-thumbs restarts generation before each gated exact seek
```

The M3 ones (`probe --json` also prints `dolbyVision`):

```sh
reelctl hdr <file> [--decoder hw|sw] [--display sdr|xdr|external|headroom=X] [--display-headroom X] [--setting full|limited|off] [--screenshot png] [--thumbnail] --json   # kind, decoded patch codes, attachments, DynamicRangePlan, tone-mapped patches, screenshot and thumbnail readbacks
reelctl energy-bench <file> --mode play|paused|occluded [--seconds N] [--warmup N] [--no-tile-check] --json   # cpuPercent, wakeupsPerSecond, engine counters, resyncMs, VP9 tile check share; no audio renderer
reelctl soak <file|dir> [--seed S] [--ops N] [--seconds N] --json    # one child per file (soak-one): crashes, hangs, leaks, manifest mismatches, dataEnd
reelctl soak --list <file>... [--seed S] [--ops N] --json            # the same on a list (the ASan run in accept.sh uses 24 files)
reelctl devices --json                                    # audio output devices (uid, name, isDefault), attaches no renderer
reelctl color <file> --frame N [--decoder hw|sw] [--screenshot png] --json   # Reel's sRGB against AVAssetImageGenerator on a 6 x 4 grid, attachments, ICC (sdr/bars*.mp4)
```

`scripts/shots.sh` compiles `scripts/shot-stats.swift` into `build/shots/bin`;
`shot-stats <png> [x y w h]` prints size and luma statistics, `--ink x y w h` counts white pixels
with a dark outline (subtitle text) and `--patch x y w h` prints the mean sRGB r g b of a region
(the HDR shots are checked with it). The ASan step of `accept.sh m3` builds into
`$TMPDIR/reel-asan` and deletes that exact path afterwards.

- FFmpeg carries one patch, `scripts/patches/ffmpeg-vp9-tile-check.patch` (the VP9 tile check of
  design 7.10); `deps.sh` applies it and hashes it into its stamp.
- `scripts/make-dovi-rpu.c` is a fixture generator built against Homebrew's FFmpeg by `fixtures.sh`
  (Dolby Vision files with real RPUs); it is never linked into Reel.
- Run `scripts/deps.sh` before the first build: it builds the static libraries and syncs their
  headers into `Sources/CReelDeps/include/` (gitignored). Swift must never see Homebrew's FFmpeg
  headers; their struct layout differs and the spike crashed with SIGBUS.
- Several agents may build at once. Always pass your own `--scratch-path` outside the repo and
  delete it by its exact path when done.
- Use `caffeinate -i` for long runs (deps, fixtures, benches).
- `check.sh` and `accept.sh` run `swift test` with `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=8`
  (at most 8 test cases at once). Unbounded, the decode tests fill the cooperative pool for the first
  seconds and the async timing tests beside them fail. Set it too when you run the whole suite.
- Set `REEL_NO_UPDATES=1` for every test, shot or `reelctl` run (check.sh and shots.sh export it).
- `scripts/release.sh` publishes a real update for the user. Agents run it only with
  `--dry-run <dir>`, and only when asked.

## Layout

- `CReelDeps`: C shim over the static libraries (`reel_averror`, `reel_err_string`, ...).
- `ReelCore`: pure Swift, Foundation only. Shared types (`MediaTime`, `MediaInfo`, `SeekRequest`,
  `SeekReport`, `EngineEvent`, `PlayerEngine`, `KeyframeIndex`, `ReelPaths`) and pure logic.
- `ReelEngine`: FFmpeg and Apple media. Nonisolated by default.
- `ReelUI`: SwiftUI and AppKit views, `@MainActor` by default. Depends only on `ReelCore` and talks
  to the engine through `PlayerEngine`.
- `Reel`: the app executable (`@MainActor` by default). `reelctl`: the headless CLI.
- Sparkle (exact 2.10.0, app-updates `CONTRACT.md`) is linked by the `Reel` target only.
  `Updater` wraps `SPUStandardUpdaterController` behind ReelUI's `UpdaterControlling`, and
  `UpdaterPolicy` returns no updater in shot mode, with `REEL_NO_UPDATES=1` or outside a `.app`.
- Swift 6 language mode, Swift Testing (`@Suite struct XTests`, `@Test func descriptiveName()`).

## Safety rules (this is the user's real Mac)

1. Never show a window, take focus or trigger a permission dialog. Never run `open`, never use
   osascript, never launch IINA or any GUI app. The Reel binary runs only in `--shot` mode (no
   `NSApplication.run`, no `NSWindow`, no updater) or as `reelctl`, always with `REEL_HOME` set to
   a temp dir and `REEL_NO_UPDATES=1`. Compare `lsappinfo front` before and after any Reel launch.
2. Never make a sound. No test, bench or tool attaches an `AVSampleBufferAudioRenderer` or any
   audio output. Never set `REEL_ALLOW_AUDIO=1`. No afplay, no say.
3. Never read the user's media or private folders (~/Downloads, ~/Desktop, ~/Movies, ~/Documents
   outside this repo, /Volumes, ~/Library/Containers, Mail, Messages, Safari, iCloud Drive). All
   media comes from `scripts/fixtures.sh`. Tests set `REEL_IINA_WATCH_LATER` to a fake dir or empty,
   never IINA's real watch_later folder.
4. Never `rm -rf` with wildcards, relative paths or after `cd`. Delete only exact absolute paths
   inside `.build`, `build/`, `vendor/build`, `vendor/prefix` or a dir you created with `mktemp`.
5. Track every process you start by PID and stop it by PID. Never kill or signal anything else.
6. No network except `scripts/deps.sh` downloading its pinned, sha256-verified tarballs and
   SwiftPM resolving Sparkle. No `URLSession`, `NWConnection` or `import Network` in `Sources/`
   (swiftlint enforces it). Sparkle in the installed app is the one runtime exception; no test,
   shot or tool ever creates an `Updater` or makes Sparkle fetch the feed.
7. Install nothing, change no system or app settings (no `defaults write`, no LaunchServices).
8. FFmpeg stays LGPL: never `--enable-gpl`, `--enable-nonfree` or `--enable-version3`.

## Style

- No em dashes or en dashes anywhere: code, comments, strings, docs, output. Use commas, colons,
  parentheses or separate sentences. Write plainly, without figurative or rhetorical prose.
- Comments only for the non-obvious (a constraint, a gotcha, a why), one or two lines.
- No `try!` in `Sources/`; no `try?` in `Sources/ReelCore/*Store*.swift` (swiftlint enforces both).
- At the Swift 6 sending boundary (`CMReadySampleBuffer(unsafeBuffer:)`), wrap fresh buffers in a
  small `@unchecked Sendable` box with a comment saying why, and nowhere else.

## Installing and updates (user preferences)

- Install new builds to /Applications without asking, but only when the app is not running (scripts/bundle.sh --release --install). Never quit a running copy to install unless the user asks.
- Auto-update goes through Sparkle 2.10.0 and the public sdusteric/app-updates repo; the contract is ~/Documents/Projects/mac-apps/app-updates/CONTRACT.md. Keep it wired in every release; agents run release.sh only with --dry-run.
