# Reel

A macOS video player for one person, replacing IINA on this Mac. Own engine: FFmpeg demux and
audio decode, direct VideoToolbox into `AVSampleBufferDisplayLayer`, `AVSampleBufferRenderSynchronizer`
as the clock. The design doc is the source of truth: `docs/superpowers/specs/2026-10-24-reel-design.md`.

## Commands

```sh
scripts/deps.sh                 # static LGPL FFmpeg 9.0.2 + libass into vendor/prefix (stamped, about 60 s cold)
scripts/fixtures.sh             # generated test media into ${REEL_FIXTURES:-build/fixtures} (stamped, about 50 s)
swift build --scratch-path "$TMPDIR/reel-<task>"
swift test --scratch-path "$TMPDIR/reel-<task>" --filter <Suite>
swiftlint lint --strict
REEL_SCRATCH="$TMPDIR/reel-check" scripts/check.sh   # every gate
```

- Run `scripts/deps.sh` before the first build: it builds the static libraries and syncs their
  headers into `Sources/CReelDeps/include/` (gitignored). Swift must never see Homebrew's FFmpeg
  headers; their struct layout differs and the spike crashed with SIGBUS.
- Several agents may build at once. Always pass your own `--scratch-path` outside the repo and
  delete it by its exact path when done.
- Use `caffeinate -i` for long runs (deps, fixtures, benches).

## Layout

- `CReelDeps`: C shim over the static libraries (`reel_averror`, `reel_err_string`, ...).
- `ReelCore`: pure Swift, Foundation only. Shared types (`MediaTime`, `MediaInfo`, `SeekRequest`,
  `SeekReport`, `EngineEvent`, `PlayerEngine`, `KeyframeIndex`, `ReelPaths`) and pure logic.
- `ReelEngine`: FFmpeg and Apple media. Nonisolated by default.
- `ReelUI`: SwiftUI and AppKit views, `@MainActor` by default. Depends only on `ReelCore` and talks
  to the engine through `PlayerEngine`.
- `Reel`: the app executable (`@MainActor` by default). `reelctl`: the headless CLI.
- Swift 6 language mode, Swift Testing (`@Suite struct XTests`, `@Test func descriptiveName()`).

## Safety rules (this is the user's real Mac)

1. Never show a window, take focus or trigger a permission dialog. Never run `open`, never use
   osascript, never launch IINA or any GUI app. The Reel binary runs only in `--shot` mode (no
   `NSApplication.run`, no `NSWindow`) or as `reelctl`, always with `REEL_HOME` set to a temp dir.
   Compare `lsappinfo front` before and after any Reel launch.
2. Never make a sound. No test, bench or tool attaches an `AVSampleBufferAudioRenderer` or any
   audio output. Never set `REEL_ALLOW_AUDIO=1`. No afplay, no say.
3. Never read the user's media or private folders (~/Downloads, ~/Desktop, ~/Movies, ~/Documents
   outside this repo, /Volumes, ~/Library/Containers, Mail, Messages, Safari, iCloud Drive). All
   media comes from `scripts/fixtures.sh`. Tests set `REEL_IINA_WATCH_LATER` to a fake dir or empty,
   never IINA's real watch_later folder.
4. Never `rm -rf` with wildcards, relative paths or after `cd`. Delete only exact absolute paths
   inside `.build`, `build/`, `vendor/build`, `vendor/prefix` or a dir you created with `mktemp`.
5. Track every process you start by PID and stop it by PID. Never kill or signal anything else.
6. No network except `scripts/deps.sh` downloading its pinned, sha256-verified tarballs. No
   `URLSession`, `NWConnection` or `import Network` in `Sources/` (swiftlint enforces it).
7. Install nothing, change no system or app settings (no `defaults write`, no LaunchServices).
8. FFmpeg stays LGPL: never `--enable-gpl`, `--enable-nonfree` or `--enable-version3`.

## Style

- No em dashes or en dashes anywhere: code, comments, strings, docs, output. Use commas, colons,
  parentheses or separate sentences. Write plainly, without figurative or rhetorical prose.
- Comments only for the non-obvious (a constraint, a gotcha, a why), one or two lines.
- No `try!` in `Sources/`; no `try?` in `Sources/ReelCore/*Store*.swift` (swiftlint enforces both).
- At the Swift 6 sending boundary (`CMReadySampleBuffer(unsafeBuffer:)`), wrap fresh buffers in a
  small `@unchecked Sendable` box with a comment saying why, and nowhere else.
