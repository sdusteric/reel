# Reel design

Date: 2026-10-24
Status: approved for M1 by the planner (the user is away and opted out of questions; every decision below is the planner's and is listed for review in "Decisions to review").

Reel is a macOS video player for one person, written to replace IINA on their Mac. It should look as calm and finished as IINA and jump to a new time much faster.

Calls that I made on the user's behalf are marked **(my call)** where they appear, and all of them are collected with ids in the last section.

## 1. Why

The user's one complaint about IINA is that jumping to a different time is slow. Their library is mostly local files: 1301 mp4, 300 mkv, 14 flv, 14 mov, 2 avi, 2 m4v. Typical content is x265 10-bit 1080p BluRay TV seasons in mkv, and 4K60 YouTube downloads from Haul in mkv (AV1 or VP9 video with Opus audio). Files live in ~/Documents, ~/Downloads and on external SSDs.

IINA is a front end for mpv, which decodes through FFmpeg. An exact seek has to decode every frame from the previous keyframe to the target. We measured this on this Mac (M5 Pro, macOS 27.0.1) with generated files at realistic bitrates (20 to 25 Mbps with noise), warm page cache:

| File | GOP | FFmpeg exact seek, worst case (IINA-like) | Direct VideoToolbox, full GOP decode |
|---|---|---|---|
| HEVC Main10 1080p24 mkv | 10.4 s | 623 ms hw / 714 ms sw | 128 ms |
| H.264 1080p30 mp4 | 10 s | 1014 ms hw / 626 ms sw | 195 ms (max 351) |
| AV1 4K60 mkv | 5 s | 1390 ms hw / 646 ms sw | 405 ms |
| VP9 4K60 webm | 5 s | 2306 ms hw / 792 ms sw | 1210 ms |

What the numbers say:

- FFmpeg's VideoToolbox hwaccel path is 3 to 7 times slower than calling VideoToolbox directly with async decode, because it decodes one frame at a time and copies every frame back to system memory. mpv uses that path, so libmpv would inherit it.
- The container index barely matters. A mkv without Cues seeked as fast as one with Cues (FFmpeg bisects).
- Process start, probing and decoder setup cost 50 to 100 ms per seek in a CLI. A resident player with a warm demuxer and a live decoder session pays only the decode.
- Native VideoToolbox returns the first frame 5 to 23 ms after a keyframe is submitted, so a keyframe-only scrub can show a real picture for every drag position.
- VP9 4K is the slow case: hardware decodes at 249 fps, software at 576 fps.

Conclusion: the spike supports the engine decision in the task (own FFmpeg demux plus Apple renderers instead of libmpv). One refinement **(my call)**: Reel runs its own `VTDecompressionSession` and enqueues decoded frames into `AVSampleBufferDisplayLayer`, instead of enqueueing compressed frames and letting the layer decode. Reasons: the layer's queue stalled after 50 frames while paused, which would stall an exact seek in the middle of a 300-frame GOP; we need to drop pre-target frames ourselves at full decode speed; and decoded frames are needed for frame grabs, screenshots and (M2) thumbnails. The software path already enqueues decoded frames into the same layer (verified, 120 of 120 frames), so both paths share one output.

## 2. Goals

1. Seeking feels instant. Every input that moves the playhead gives visual feedback within one display refresh and a real picture within 50 to 80 ms. Exact seeks land in under 250 to 550 ms in the worst case for the user's common formats (targets in section 7.6).
2. As beautiful and quiet as IINA: a borderless-feeling window sized to the video, a floating frosted controller, chrome that fades away, correct light and dark appearance.
3. Plays the user's files: H.264, HEVC 8 and 10-bit, AV1, VP9 and older codecs in mp4, mkv, webm, mov, flv, avi and ts, with AAC, AC3, E-AC3, Opus, FLAC, DTS, TrueHD and others decoded in software.
4. Never loses the resume position, and carries over IINA's saved positions.
5. Keeps IINA's key bindings, since the user never customised them.
6. One self-contained, signed .app with no runtime dependency on Homebrew.

## 3. Non-goals

- Streaming sites, URL playback, yt-dlp, OpenSubtitles or any network feature. Haul handles downloads.
- A media library or browser. Reel opens files; it does not catalogue them.
- Editing, trimming, transcoding, export.
- Plugins or scripting.
- Mac App Store distribution, sandboxing, other users' Macs. Reel is for this one Mac (macOS 27, Apple Silicon).
- Matching every mpv option.

## 4. Anti-goals

These are failures, not missing features. Each has a guard in the design.

- **A seek that freezes the picture without feedback.** The seek bar and time label move on input before any decode starts, a keyframe preview appears within 80 ms, and the old frame stays on screen (never black) until the new one is ready. Section 7.5.
- **Losing the resume position.** Saved every 5 s, on pause, on seek settle, on close and on quit, with atomic writes. Section 11.
- **A window that steals focus.** Reel never calls `activate` on its own. Tests and screenshots never create an on-screen window and check that the frontmost app is unchanged. Section 14.
- **Anything that phones home.** No network code. FFmpeg is built with `--disable-network`, there is no updater, no analytics, no crash reporter. A lint rule rejects `URLSession`, `NWConnection` and `Network` imports in `Sources/`. Section 13.

## 5. Supported formats

Containers (FFmpeg demuxers): mp4, m4v, mov (mov), mkv, webm (matroska), flv, avi, ts, m2ts, mts (mpegts), ogg/ogv, plus wav, mp3, aac, flac for audio-only files.

Video:

| Codec | Decoder | Notes |
|---|---|---|
| H.264 (avcC and Annex B) | VideoToolbox hardware | Annex B (ts) converted to length-prefixed NAL units |
| HEVC Main and Main10 | VideoToolbox hardware | hvcC; HDR10 and HLG colour carried in the format description |
| AV1 | VideoToolbox hardware when `VTIsHardwareDecodeSupported` (true on this M5), else dav1d | av1C from extradata |
| VP9 profile 0 and 2 | VideoToolbox hardware after `VTRegisterSupplementalVideoDecoderIfAvailable` | vpcC built from codecpar |
| MPEG-4 Part 2, MS-MPEG4 v3, FLV1 (Sorenson H.263), MPEG-2, VC-1 | libavcodec software | old avi and flv files |

Audio: everything goes through libavcodec and swresample to interleaved 32-bit float LPCM: AAC, AC3, E-AC3, DTS, TrueHD/MLP, FLAC, Opus, Vorbis, MP3, ALAC, PCM. Passthrough of compressed audio is not used **(my call)**: AudioToolbox has no DTS or TrueHD decoder, and one LPCM path is simpler to make sample-accurate.

Subtitles (M2): SRT, ASS/SSA, WebVTT, mov_text, PGS, DVD/VobSub, external files next to the video.

Known gaps: Dolby Vision profile 5 (single-layer IPT) will show wrong colours; profile 8 plays as its HDR10 base layer. DTS-HD MA and TrueHD Atmos play as their core or bed channels. 4:2:2 and 4:4:4 content goes to the software path and is untested.

## 6. Architecture overview

```
 Main actor                 Engine (ReelEngine)                                   Apple renderers
 ----------                 -------------------                                   ---------------
 PlayerModel  <-- events -- PlaybackEngine (actor)
 input, UI    -- commands ->   |  SeekPlanner, DecoderPolicy (ReelCore, pure)
                               |
                         Demuxer thread  --packets-->  PacketStore (per stream, GOP-indexed)
                               |                          |                 |
                               |                     VideoPipeline      AudioPipeline
                               |                     VT session or      libavcodec + swresample
                               |                     libavcodec/dav1d   (audio thread)
                               |                          |                 |
                               |                     decoded CVPixelBuffers  LPCM CMSampleBuffers
                               |                          v                 v
                               |                   video Receiver      audio Receiver
                               |                          \                /
                               +------------------ AVSampleBufferRenderSynchronizer (clock)
                                                          |
                                         AVSampleBufferDisplayLayer (in the window)
```

## 7. Engine

### 7.1 Threads, actors and queues

- **Main actor.** UI, `PlayerModel`, input handling, and the `AVSampleBufferDisplayLayer` (it is main-actor isolated). Receives `EngineEvent`s through an `AsyncStream`.
- **`PlaybackEngine` actor.** Owns the state machine (idle, opening, ready, playing, paused, seeking, ended, failed), the seek generation counter, the synchronizer rate calls and the resume hooks. All public commands go through it.
- **Demuxer thread.** One dedicated `Thread`, not a Swift concurrency task, because `av_read_frame` blocks on I/O and must not sit on the cooperative pool **(my call)**. It owns the `AVFormatContext`. It takes commands (seek, set active streams, stop) from a lock-protected queue that it checks between packets, so a seek preempts read-ahead within one packet.
- **Video decode.** VideoToolbox decodes on its own threads and calls back with frames; the callback tags each frame with the seek generation and hands it to `VideoPipeline` through an `AsyncStream`. The software decoder runs on its own dedicated thread with libavcodec frame threading (thread count = performance core count) or dav1d threads.
- **Audio decode.** One dedicated thread. It is cheap (the heaviest case, TrueHD, is a few percent of a core).
- **Clock.** `AVSampleBufferRenderSynchronizer` is the only clock. The UI reads it through a periodic time observer: 10 Hz while the chrome is visible, 1 Hz while hidden.

The macOS 27 receiver API is used: `sync.sampleBufferReceiver(adding:)` for both renderers, `try await receiver.enqueue(_:)` (suspends under back-pressure), `flush(removingDisplayedImage:)`, and the rendering event sequences for decode failures and audio configuration changes. Receivers are returned as `sending`, so each one is moved into the actor that enqueues on it. Deployment target is macOS 27 because this API is macOS 27 only **(my call)**.

### 7.2 Demux and packet store

- Open with `avformat_open_input`, then `avformat_find_stream_info` with `probesize` 5 MB and `analyzeduration` 2 s **(my call)**, enough for every fixture and short enough to keep open time low. If a stream still lacks parameters, retry once with defaults.
- Stream selection at open: the default video stream (the first non-attached-picture video stream); audio by the container default flag, then the first. M2 adds language preferences.
- **Keyframe index.** Built at open from `avformat_index_get_entry` on the video stream (mkv Cues, mp4 stss) and extended with every packet carrying `AV_PKT_FLAG_KEY` that the demuxer reads. Each entry stores presentation pts, dts, byte position and kind (IDR, CRA, other). Lookups are by **presentation pts** with reorder delay accounted for, which avoids the extra-GOP quirk the spike saw with FFmpeg's dts-based lookup on 8-B-frame HEVC (a target 0.2 s after a keyframe landed in the previous GOP).
- **PacketStore.** Compressed packets for the active streams, grouped by video GOP (keyed by keyframe pts). It keeps up to 30 s or 192 MB behind the playhead and reads ahead up to 20 s or 192 MB **(my call)**. A short backward jump then needs no I/O, only the decode from the retained GOP start. Packets are ref-counted `AVPacket`s; CMBlockBuffers point at their data with a custom block source that unrefs on free (zero copy, verified).
- On a seek outside the stored range, the demuxer calls `avformat_seek_file` on the video stream with `max_ts` = the chosen keyframe pts and `AVSEEK_FLAG_BACKWARD`, discards packets before the keyframe, and refills from there. Audio packets are read in the same pass.

### 7.3 Video decode paths

**Format descriptions** (`FormatDescriptionBuilder`, verified byte-identical to Apple's own for avcC, hvcC, av1C):
- H.264, HEVC, AV1: `CMVideoFormatDescriptionCreate` with `SampleDescriptionExtensionAtoms` = `avcC` / `hvcC` / `av1C` from `codecpar.extradata`.
- H.264/HEVC Annex B (ts, or extradata not starting with 1): parameter sets via `CMVideoFormatDescriptionCreateFromH264ParameterSets` / `...HEVC...` with 4-byte NAL lengths; every packet is rewritten from start codes to length prefixes.
- VP9: build `vpcC` from codecpar (version 1, profile, level 0, bit depth, chroma, range, primaries, transfer, matrix). Call `VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)` once at launch.
- Colour: always set `ColorPrimaries`, `TransferFunction`, `YCbCrMatrix`, `FullRangeVideo` from codecpar. When codecpar is unspecified (AV1 in mkv often is), software-decode one frame with libavcodec (2 to 9 ms) and read the frame's colour fields, mastering display metadata and content light level. If still unknown: BT.709 for height 720 and above, SMPTE-C/601 below. HDR10: `MasteringDisplayColorVolume` (24 bytes, G B R order) and `ContentLightLevelInfo`.
- Pixel aspect ratio and the display matrix rotation (90/180/270, common in .mov phone clips) are applied: aspect through `PixelAspectRatio` and the window size, rotation through the layer transform.

**Hardware path (`VTVideoDecoder`).** One `VTDecompressionSession` per video stream, kept alive for the whole file. Flags `_EnableAsynchronousDecompression` and, during a seek burst, `_1xRealTimePlayback` off. Output attributes request `420v` (8-bit) or `x420` (10-bit) with IOSurface and Metal compatibility **(my call)**: these formats are verified to enqueue into the layer; the native compressed `&8v0`/`&xv0` formats might be faster but are unverified as uncompressed input to the layer. If the session cannot be created, or three consecutive frames fail after a keyframe, `DecoderPolicy` switches the stream to software at the next keyframe and logs why.

**Software path (`SoftwareVideoDecoder`).** libavcodec (dav1d for AV1). Output converted with swscale into a `CVPixelBufferPool` (NV12 or P010, IOSurface-backed, allocation threshold 12; on `kCVReturnWouldExceedAllocationThreshold` it waits instead of failing). Colour attachments set with `.shouldPropagate`. Cost measured at 0.25 ms (NV12) and 1.1 ms (P010) per 1080p frame.

**Output (`VideoOutput`).** Decoded frames become `CMSampleBuffer`s via `CMVideoFormatDescriptionCreateForImageBuffer` and `CMSampleBufferCreateReadyWithImageBuffer` with the stream pts. The decoded-ahead queue holds at most 8 frames (a 4K P010 frame is about 25 MB) **(my call)**. Frames whose generation is older than the current seek generation are dropped before enqueue.

**Decoder policy** (`DecoderPolicy`, pure, in ReelCore): H.264, HEVC 4:2:0 8/10-bit and VP9 use hardware; AV1 uses hardware when supported, else dav1d; everything else uses software. `REEL_FORCE_DECODER=hw|sw` overrides for tests and benches. The VP9 hybrid (software for long exact seeks, hardware for steady playback, handing over at the next keyframe) is deferred to M2 **(my call)** because it needs a decoder hand-off; M1 measures VP9 and reports it.

### 7.4 Audio and A/V sync

- Decode with libavcodec, convert with swresample to interleaved float32 at the source rate. ASBD: LinearPCM, flags IsFloat | IsPacked, 32 bits, bytesPerFrame = 4 x channels.
- Channel layout via `kAudioChannelLayoutTag_UseChannelDescriptions` in FFmpeg's native order (FL FR FC LFE then sides/backs; BL/BR become LeftSurround/RightSurround when there are no side channels, RearSurroundLeft/Right when both exist). No reordering.
- Coalesce decoded frames into buffers of about 20 ms (TrueHD decodes 40-sample frames).
- **Timestamps.** The first decoded frame after open or seek takes its pts from the packet (after libavcodec applies skip_samples for Opus pre-skip and the mp4 edit list for AAC priming). From then on pts = first pts + running sample index / sample rate, so audio time never accumulates rounding from container timestamps (mkv uses 1 ms). If a packet's pts differs from the running time by more than 40 ms (a gap or a splice), the running index re-anchors to the packet.
- Both renderers are attached to one synchronizer, audio before the first enqueue. With an audio renderer attached the clock follows the audio device; without audio it follows the host clock. Video presents against that clock, so sync is a matter of correct timestamps, which the av-sync check measures (section 14).
- Volume: `audioRenderer.volume = (v / 100)^3`, the same cubic curve mpv uses, so the user's IINA level 47 sounds the same **(my call)**. Range 0 to 100 in M1. Mute is `isMuted`.
- Pitch algorithm `.timeDomain` (the default) so M2 speed changes keep pitch.
- Device changes: on `.outputConfigurationChanged` or a suggested flush, flush audio and re-enqueue from the current time (unverified on hardware; logged).

### 7.5 Seek algorithm

Two request kinds, both from `SeekRequest`:

- `.scrub(t)`: while dragging the seek bar or during continuous horizontal scroll.
- `.exact(t)`: release of a drag, click on the bar, arrow keys, frame steps, resume, page keys.

Shared bookkeeping: every request increments `generation`. Work and frames tagged with an older generation are discarded at every stage boundary (demux command queue, decode callback, output enqueue). At most one decode burst is in flight; a new request cancels the old one by generation, not by waiting.

**Scrub(t).**
1. The UI has already moved the thumb and time label to t (no engine round-trip).
2. Coalesce: if a scrub is in flight, store t as `pendingScrub` and return. When the in-flight scrub finishes, run the latest pending one.
3. K = last keyframe with pts <= t. If K is the keyframe already displayed, do nothing.
4. Get K's packet from the store, or ask the demuxer for it (one seek, one packet read).
5. Decode K alone and enqueue it as the displayed frame with the clock at rate 0. Target 50 ms (1080p) / 80 ms (4K) p95.
6. If the pointer rests on one position for 150 ms during a drag, start the exact seek for t in the background so the release lands immediately **(my call)**.

**Exact(t).**
1. `sync.setRate(0, time: t)`; flush both receivers with `removingDisplayedImage: false`, so the old picture stays.
2. Plan (`SeekPlanner`, pure and unit-tested). Candidate starts: (a) K, the last keyframe with pts <= t; (b) the decoder's current position, if the decoder is live, t is ahead of it, and no keyframe lies between them that would be cheaper. Cost = number of frames to decode. Choose the cheaper. Forward arrow-key seeks within the GOP being played usually take (b): a 5 s step at 24 fps is 120 frames, about 60 ms of HEVC hardware decode, with no flush.
3. If starting from K and the predicted cost exceeds 150 ms (frames / measured decode rate, with defaults from the spike), decode K first and display it as a preview, then continue. The preview gives a real picture near t within the scrub budget **(my call)**.
4. Feed packets K..t to the decoder as fast as it accepts them. Frames before t are decoded but never converted or enqueued. Skip submitting frames that nothing references:
   - H.264: NAL units with `nal_ref_idc == 0`.
   - HEVC: VCL NAL types 0, 2, 4, 6, 8, 10, 12, 14 (sub-layer non-reference), only when the stream has one temporal sub-layer (hvcC `numTemporalLayers` == 1).
   - HEVC RASL pictures (types 8, 9) after a CRA we start from, since they reference the previous GOP and cannot decode.
   - AV1 and VP9: no skipping in M1.
5. The first frame with pts <= t < pts + duration is the target. Enqueue it, then keep decoding ahead normally.
6. Audio: take audio packets from t minus the codec preroll (80 ms for Opus, one frame otherwise), decode, drop buffers that end before t, trim the head of the buffer that straddles t in the app, enqueue.
7. When the target frame is enqueued and audio is primed (or there is no audio): if the user was playing, `sync.setRate(1, time: t)`; otherwise stay paused on the target frame.
8. Emit `SeekReport` (request time, preview time, target time, frames decoded, frames skipped, bytes read, whether the store hit) and update the resume position.

Frame step forward (`.`) decodes the next frame while paused. Frame step back (`,`) is `exact(t - frameDuration)`, cheap because the GOP is in the store.

### 7.6 Latency targets

Measured on generated fixtures, warm page cache, M5 Pro, inside a resident engine (no process start). These are the M1 acceptance thresholds (section 16); the measured basis is in brackets.

| Fixture | First frame after open p95 | Keyframe (scrub) seek p95 | Exact seek, worst case p95 | IINA-like baseline (FFmpeg worst case) |
|---|---|---|---|---|
| HEVC Main10 1080p24 mkv, 10.4 s GOP | 200 ms | 50 ms | 250 ms (full GOP 128 ms) | 623 to 714 ms |
| H.264 1080p30 mp4, 10 s GOP | 200 ms | 50 ms | 350 ms (full GOP 195 ms, max 351) | 626 to 1014 ms |
| AV1 4K60 mkv, 5 s GOP | 200 ms | 80 ms | 550 ms (full GOP 405 ms) | 646 to 1390 ms |
| VP9 4K60 webm, 5 s GOP | report only | report only | report only (expect about 1.2 s) | 792 to 2306 ms |

"Worst case" means the target is the last frame before the next keyframe, so a whole GOP is decoded. Real BluRay HEVC and real YouTube AV1 carry more detail per frame than the noise fixtures, so these are lower bounds on real files; the keyframe preview covers the gap.

## 8. Subtitles (M2)

- libass 0.17.5 with the CoreText font provider (verified: Chinese, kana and fallback fonts render; first frame 46 ms, then 24 ms; `changed == 0` lets us skip re-blending).
- Embedded text tracks: packets decoded with `avcodec_decode_subtitle2`; `rect.ass` goes to `ass_process_chunk`, `subtitle_header` to `ass_process_codec_private`.
- External files: same stem as the video, case-insensitive, exact or `stem.` prefix (`movie.en.srt`, `movie.zh-Hans.srt`, `Movie.EN.forced.srt`); `.sub` only with a sibling `.idx`. Remaining dot tokens parse as language and flags (forced, sdh).
- Charset: try UTF-8; if libavcodec reports invalid UTF-8, reopen with `sub_charenc=GB18030` and `sub_charenc_mode=pre_decoder` (the user reads Chinese; GBK srt files are common) **(my call)**.
- Bitmap subtitles (PGS, DVD): PAL8 rects converted to premultiplied CGImages, scaled from the decoder's canvas size to the video size.
- Track choice: first track whose language matches `zho`/`chi`/`zh*`, then `eng`/`en*`, preferring non-forced; external files compete with embedded tracks by the same order. This mirrors the user's IINA `subLang zho,eng`.
- Size: default font scale 45 on mpv's 720-line reference (6.25% of video height), the user's IINA `subTextSize` **(my call; the mapping from IINA's value is my reading of mpv's scale, unverified against IINA on screen)**. White, 1.5 pt soft black outline, no box. ASS styles keep their own fonts.
- Rendering: blend the `ASS_Image` list into one RGBA bitmap over its dirty rect, set as `contents` of a `CALayer` above the video layer, driven by the synchronizer's periodic observer at 1/30 s.

## 9. Window and controls

All sizes in points.

### 9.1 Window

- `NSWindow`, `styleMask [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable]`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `isMovableByWindowBackground = true`, `tabbingMode = .disallowed`, background black. AppKit app lifecycle (`NSApplicationDelegate`), SwiftUI for the overlay and settings content **(my call)**: it gives direct control of the window, the layer and focus.
- Content view: a layer-backed `PlayerContentView` (black) containing the `AVSampleBufferDisplayLayer` (`videoGravity = .resizeAspect`) and, above it, an `NSHostingView` with the SwiftUI chrome (controller, OSD, title).
- One window. Opening a new file replaces the current one (IINA `alwaysOpenInNewWindow = 0`).
- First open: size to the video's display size (after pixel aspect and rotation), scaled down to fit 80% of the screen's visible frame, centred. On the user's 3440x1440 display a 1080p video opens at 1920x1080. Later opens keep the window's centre and width, set the height from the new aspect, and clamp to the screen. `contentAspectRatio` = the video aspect, so resizing keeps it. The frame is saved in `state.json`.
- Empty state (no file): 720x450, black, centred text "Open a video" (15 pt semibold, secondary) and "Drop a file here or press ⌘O" (12 pt, tertiary). The whole window is a drop target.
- Fullscreen: native `toggleFullScreen(_:)` with `.fullScreenPrimary`. M1 supports it without polish; the controller keeps its fractional position.
- Display sleep: `IOPMAssertionCreateWithName(PreventUserIdleDisplaySleep, "Reel is playing video")` while playing, released on pause, close and quit.

### 9.2 Chrome visibility

- The traffic lights, title and controller share one `chromeVisible` state.
- Shown on pointer movement of 2 pt or more inside the window, on any key that changes playback (shown for the auto-hide period), and always while paused.
- Hidden after 2.5 s without input while playing. Never hidden while the pointer is over the controller or a drag is in progress.
- The cursor hides with the chrome (`NSCursor.setHiddenUntilMouseMoves(true)`) only when the pointer is over the video.
- Fade in 0.22 s ease-out, fade out 0.35 s ease-in. Traffic lights fade through `standardWindowButton(_:)?.animator().alphaValue` in the same transaction. With Reduce Motion: opacity only, 0.1 s.

### 9.3 Controller

- A SwiftUI view inside the hosting view (not a separate window).
- Shape: rounded rectangle, corner radius 22, height 76, width 480 (min 360, max 560, never more than 70% of the window width), padding 14 horizontal, 10 vertical.
- Material: `.regularMaterial` in both appearances, 0.5 pt inner stroke (white 12% in dark, black 8% in light), shadow radius 24, y 8, opacity 0.25. Not Liquid Glass **(my call)**: a headless `ImageRenderer` test on this Mac rendered `.regularMaterial` correctly in light and dark but rendered nothing at all for `.glassEffect`, so glass would break the background screenshots that are our UI check. Revisit in M2 if a capture path for glass exists.
- Position: stored as fractions of the window (x of the centre, y of the bottom edge from the window bottom), default x 0.49, y 0.11 (the user's saved IINA position). Draggable by any area that is not a control; follows the pointer with no animation; clamped to keep 16 pt from every edge. Double-click on an empty area resets it.
- Top row: elapsed time (left), seek bar (fills), remaining time (right, `-12:34`, default because the user has `showRemainingTime` on). Clicking the right label toggles remaining and total; persisted.
- Bottom row: left, volume icon (click toggles mute) plus a 72 pt slider that widens to 120 on hover; centre, back 10 s, play/pause (32 pt hit circle, 22 pt glyph), forward 10 s; right, fullscreen. M2 adds previous/next, subtitle, audio, speed and PiP buttons.
- Times: `.system(size: 12, weight: .medium).monospacedDigit()`, primary at 85%. Hours shown only when duration is 1 h or more.
- Icons: SF Symbols, medium weight, 17 pt (play 22 pt), `.primary` at 90%, 55% disabled. Hit targets at least 28 pt; hover background `Color.primary.opacity(0.08)` circle fading in over 0.12 s. Play/pause swaps with `.contentTransition(.symbolEffect(.replace))`.

### 9.4 Seek bar

- Track 4 pt tall, grows to 8 pt on hover (spring, 0.18 s). Unplayed: primary 20%. Stored-in-memory range (the PacketStore window): primary 35%. Played: accent colour. Thumb: 12 pt circle, visible on hover and drag only.
- Hover pill above the track: time under the pointer in 12 pt semibold monospaced digits, on the same material. It follows x with no animation and fades in over 0.1 s. M2 adds a thumbnail above the time.
- Drag sends `.scrub(t)` on every move (coalesced in the engine); release sends `.exact(t)`. Click without drag sends `.exact(t)`.
- A resume tick (2 pt wide, primary 50%) marks the saved position when the file was resumed.

### 9.5 OSD

- Top-left, 20 pt from the edges, 20 pt semibold rounded text on the controller material, corner radius 10.
- Shown for volume ("Volume 52"), mute, seeks from the keyboard ("12:04 / 1:02:33"), frame steps, and resume ("Resumed at 23:10", with a "Start Over" button that stays for 5 s).
- Appears with a 0.12 s fade and scale 0.96 to 1, stays 0.9 s after the last update, fades out over 0.25 s. Repeated updates change the text in place without re-animating.
- If an exact seek has not landed after 400 ms, a small progress ring appears next to the time in the OSD.

### 9.6 Pointer and gestures

- Single click on the video: toggle pause, delayed 250 ms to allow a double click. Double click: toggle fullscreen.
- Two-finger horizontal scroll: seek. Continuous scroll sends scrubs (1 s of media per 8 pt of scroll, my default) and an exact seek when the gesture ends **(my call)**. Vertical scroll: volume, 1 step per 6 pt. Natural scrolling is respected.
- Drag on the video moves the window. Right click: context menu with Open, Play/Pause, Show in Finder.

## 10. Key bindings

IINA's defaults, because the user never changed them. M1 binds the items without a tag; M2 items are marked.

| Keys | Action |
|---|---|
| Space, p, media play/pause | Toggle pause |
| Right / Left | Seek +5 / -5 s (exact) |
| Shift+PgUp / Shift+PgDn | Seek +600 / -600 s |
| . / , and Alt+Right / Alt+Left | Frame step forward / back |
| Up / Down | Volume +5 / -5; with Alt +1 / -1 |
| m, Cmd+/ | Mute |
| f, Ctrl+Cmd+F, Return | Toggle fullscreen; Esc leaves it |
| Cmd+O | Open |
| Cmd+W | Close file (window returns to the empty state) |
| Cmd+Q, q | Quit (saves resume) |
| Cmd+0 / 1 / 2 / 3 | Window scale 0.5 / 1 / 2 / fit screen |
| Cmd+, | Settings |
| Shift+Right / Shift+Left (M2) | Next / previous subtitle line |
| Cmd+Right / Cmd+Left (M2) | Next / previous file in folder |
| Cmd+] / Cmd+[ / Cmd+\ (M2) | Speed x2, x0.5, reset; Alt+Cmd variants x1.1 and /1.1 |
| z / x / c, Shift+9 / Shift+0 (M2) | Subtitle and audio delay |
| v, r, t, Shift+G, Shift+F (M2) | Subtitle show/hide, move, size |
| Ctrl+Cmd+S / A / V (M2) | Cycle subtitle / audio / video track |
| Ctrl+Cmd+P (M2) | Picture in Picture |
| Cmd+S (M2) | Screenshot to ~/Pictures |
| Cmd+L, Shift+Cmd+L (M2) | A-B loop, file loop |

Bindings live in one table (`InputMap` in ReelCore) loaded from a bundled `input.conf` in IINA's syntax, so a user file can override it later. Key repeat on arrows issues exact seeks; the planner usually continues forward without a flush, and repeats faster than the engine can serve are coalesced like scrubs.

## 11. Settings, resume and data

### 11.1 Settings (M1)

A small Settings window (`Cmd+,`), SwiftUI form, four items:
- Resume playback where I left off (on).
- Show remaining time (on).
- Show a keyframe preview while seeking (on).
- Hardware decoding (on; off forces software, for diagnosis).

Volume, remaining-time toggle, window frame and controller position are remembered state, not settings. First-run volume is 47, the user's IINA level **(my call)**.

### 11.2 Resume

- Key: a content key, SHA-256 of (file size, first 64 KiB, last 64 KiB), computed at open (about 1 ms on SSD) **(my call)**. It survives renames, moves and different mount points of an external SSD. The last known path is stored for display and debugging only.
- Stored per entry: position, duration, audio stream index, (M2) subtitle choice and delays, updated-at.
- Saved every 5 s while playing, on pause, when a seek settles, on close, on quit and on `applicationWillTerminate`. Writes are debounced to at most one per second, written to a temp file and renamed (atomic).
- Not saved when the position is under 5 s. At less than 30 s from the end, the entry is deleted (finished).
- On open, if an entry exists and the setting is on, the first seek is `.exact(position)` and the OSD shows "Resumed at mm:ss" with Start Over.
- **IINA carry-over (my call).** If Reel has no entry, it reads IINA's mpv watch_later file for the same path, read-only: `~/Library/Application Support/com.colliderli.iina/watch_later/<MD5 of the absolute path, uppercase hex>`, and takes the `start=` value. The first save then writes Reel's own entry. Override the folder with `REEL_IINA_WATCH_LATER` (empty disables it; tests always set it).
- Reel never writes to the system recent-documents list and has no Open Recent menu (the user has `recordRecentFiles` off).

### 11.3 Files

`REEL_HOME` (default `~/Library/Application Support/Reel`), like Haul's `HAUL_HOME`. Tests and screenshots always set a fresh temp dir.

| Path | Contents |
|---|---|
| `REEL_HOME/settings.json` | the four settings |
| `REEL_HOME/state.json` | volume, remaining-time toggle, window frame, controller fractions |
| `REEL_HOME/resume.json` | resume entries keyed by content key, versioned schema |
| `REEL_HOME/logs/reel.log` | local log, rotated at 5 MB, never sent anywhere |
| `REEL_HOME/Caches/` | (M2) thumbnails |

JSON files instead of `UserDefaults` **(my call)**: one env var isolates everything for tests, and the files are easy to inspect.

Environment variables: `REEL_HOME`, `REEL_FIXTURES` (fixture dir for tests and benches), `REEL_IINA_WATCH_LATER`, `REEL_FORCE_DECODER=hw|sw`, `REEL_LOG=debug`, `REEL_ALLOW_AUDIO=1` (lets a test attach an audio renderer; otherwise none is attached).

## 12. Package layout

One SwiftPM package, `swift-tools-version: 6.4`, `platforms: [.macOS(.v27)]`, Swift 6 language mode (complete concurrency checking). No Xcode project; `scripts/bundle.sh` assembles the .app the way Haul's does **(my call)**: everything builds and tests from the command line.

```
Package.swift
CLAUDE.md                          build, test and safety rules for agents
.swiftlint.yml
resources/Info.plist.in, resources/input.conf, resources/AppIcon.png (optional)
scripts/deps.sh                    pinned static FFmpeg + libass build
scripts/fixtures.sh                generated test media (Homebrew ffmpeg as a build tool)
scripts/check.sh                   all gates
scripts/bundle.sh, scripts/make-icon.swift
scripts/shots.sh, scripts/winlist.swift
scripts/accept.sh, scripts/accept-lib.sh
Sources/CReelDeps/                 C target: include/CReelDeps.h, include/module.modulemap,
                                   include/<synced FFmpeg and libass headers>, shim.c
Sources/ReelCore/                  pure Swift, Foundation only: MediaTime, MediaInfo, SeekRequest,
                                   SeekReport, EngineEvent, PlayerEngine protocol, KeyframeIndex,
                                   SeekPlanner, DecoderPolicy, InputMap, ResumeStore, ContentKey,
                                   IINAWatchLater, SettingsStore, StateStore, ReelPaths, TimeFormat
Sources/ReelEngine/                FFmpeg + Apple media: Demuxer, PacketStore, FormatDescriptionBuilder,
                                   NALUnits, VTVideoDecoder, SoftwareVideoDecoder, VideoOutput,
                                   AudioDecoder, AudioOutput, PlaybackEngine, FrameGrabber, BuildInfo
Sources/ReelUI/                    SwiftUI + AppKit views: PlayerModel (@Observable, @MainActor),
                                   PlayerSceneView, ControllerView, SeekBar, OSDView, EmptyStateView,
                                   ChromeVisibility, ShotRenderer
Sources/Reel/                      app executable: main/AppDelegate, PlayerWindowController,
                                   PlayerContentView, MainMenu, KeyHandling, OpenAndDrop, SettingsView
Sources/reelctl/                   CLI: probe, decode-bench, seek-bench, av-sync
Tests/ReelCoreTests/, Tests/ReelEngineTests/, Tests/ReelUITests/
```

- `CReelDeps` links the static libraries from `vendor/prefix/lib` with `-L` through `unsafeFlags` (allowed for a root package), plus `z`, `bz2`, `iconv`, `c++` and the Apple frameworks. FFmpeg and libass headers are copied into `Sources/CReelDeps/include/` by `deps.sh` because Swift's clang importer also searches `/opt/homebrew/include`, and Homebrew's FFmpeg headers have a different struct layout (the spike crashed with SIGBUS until this was fixed). The copied header folders are gitignored.
- `CReelDeps.h` adds `reel_averror`, `reel_averror_eof`, `reel_averror_eagain`, `reel_av_nopts`, `reel_av_time_base`, `reel_err_string`, since Swift cannot import those macros.
- `ReelCore` has no dependencies so that logic tests run in milliseconds. `ReelUI` and `Reel` use default `MainActor` isolation (`.defaultIsolation(MainActor.self)`); `ReelCore` and `ReelEngine` stay nonisolated by default **(my call)**.
- `ReelUI` depends only on `ReelCore` and talks to the engine through the `PlayerEngine` protocol, so the UI can be built and tested with a fake engine while the engine is in progress.
- Bridging into Swift 6: `CMReadySampleBuffer(unsafeBuffer:)` needs a disconnected value; wrap fresh buffers in a small `@unchecked Sendable` box only at that boundary, with a comment saying why.
- Comments: only for the non-obvious (a constraint, a gotcha, a why), one or two lines.

## 13. Dependency build

`scripts/deps.sh` is the script the spike ran end to end (61 s from cached tarballs on this Mac), with paths moved to match the repo's `.gitignore`: tarballs in `vendor/src/`, build trees in `vendor/build/`, install prefix `vendor/prefix/` (add to `.gitignore`). Source of truth to copy: `/var/folders/fy/yldrtr7n2s59dz4mqzyf6x7r0000gn/T/reelbuild.xPhWx3/scripts/deps.sh`.

| Source | Version | sha256 | License |
|---|---|---|---|
| FFmpeg | 9.0.2 | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` | LGPL 2.1+ |
| libass | 0.17.5 | `2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc` | ISC |
| HarfBuzz | 15.0.0 | `968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df` | MIT |
| FriBidi | 1.0.17 | `6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2` | LGPL 2.1 |
| FreeType | 2.15.0 (GitHub tag archive) | `87c7f1f8699b91e89f773f7dcfa505b044e1dae67f62a55d4e29c3afdcac4fb8` | FTL (chosen) |
| dav1d | 1.5.4 | `2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011` | BSD-2 |

Key points of the script:
- Xcode's clang, arm64 only, `MACOSX_DEPLOYMENT_TARGET=14.0` for the C libraries (the verified value; it links fine into a macOS 27 app) **(my call to keep it)**.
- No Homebrew libraries are linked; Homebrew only supplies build tools (meson, ninja, nasm, pkg-config, autotools). FreeType gets `-Dhvf=disabled`; HarfBuzz is built without glib, ICU, cairo, graphite.
- Meson here is an x86_64 binary under Rosetta, so the script always passes an explicit arm64 cross file (key `pkgconfig`).
- FFmpeg: `--disable-everything` plus an explicit list of demuxers, parsers, decoders and bitstream filters, `--disable-network`, `--disable-autodetect`, `--enable-libdav1d`, `--enable-videotoolbox`. No `--enable-gpl`, `--enable-nonfree` or `--enable-version3`, ever.
- A stamp file keyed by the script's hash skips rebuilds; `FORCE=1` rebuilds.
- `reelctl probe --build-info` prints `avformat_license()` and `avformat_configuration()`; the check gate requires "LGPL version 2.1 or later" and the absence of `--enable-gpl` and `--enable-nonfree`.

LGPL: Reel is personal and not distributed, so there are no obligations today. If it is ever shared, switch FFmpeg and FriBidi to dynamic frameworks inside the bundle, ship license texts and source offers (see the research notes). This is recorded, not built.

## 14. Test strategy

Rules for every test, bench and script:
- Media comes only from `scripts/fixtures.sh`, generated with ffmpeg into `REEL_FIXTURES` (default `build/fixtures`, gitignored). Never the user's videos, never ~/Downloads, ~/Documents, ~/Desktop or /Volumes.
- No test shows a window, activates an app, or triggers a permission dialog. No `open`, no osascript, no LaunchServices registration in tests.
- No test makes sound. No audio renderer is attached unless `REEL_ALLOW_AUDIO=1`, and then volume is 0 and muted. (The research spike played tones through the user's default output by accident; this rule exists because of that.)
- Every process a script starts is tracked by PID and stopped by PID, as in Haul's accept scripts. Temp dirs are removed only by the exact path `mktemp` printed.

**Fixtures** (`scripts/fixtures.sh`, recipes from the spike's `hard.sh`, `testsrc2` plus temporal noise so software decode is not flattered; stamp-cached):

| File | Content |
|---|---|
| `hevc10_1080p24.mkv` | libx265 Main10, keyint 250, scenecut 0, 8 B-frames (open GOP), 20 Mbps, 60 s, AC3 5.1 |
| `av1_2160p60.mkv` | libsvtav1 preset 9, GOP 300, 25 Mbps, 40 s, Opus |
| `h264_1080p30.mp4` | libx264 veryfast, keyint 300, scenecut 0, 20 Mbps, 60 s, AAC |
| `vp9_2160p60.webm` | libvpx-vp9 realtime cpu-used 8, GOP 300, 25 Mbps, 40 s, Opus |
| `sync_h264_aac.mp4`, `sync_hevc_opus.mkv` | 20 s; every second a white flash frame and a 1 kHz 50 ms beep at the same pts |
| `hdr10_hevc.mkv` | 2 s x265 Main10 tagged BT.2020/PQ with mastering metadata |
| `rot90_h264.mov` | 2 s with a 90 degree display matrix |
| `annexb_h264.ts`, `mpeg4.avi`, `flv1.flv` | 2 s each, small |
| `nocues_hevc.mkv` | the HEVC file remuxed without Cues |

**Unit tests (Swift Testing, `@Suite struct XTests`, `@Test func descriptiveName()`):**
- ReelCore: KeyframeIndex lookups with reorder; SeekPlanner cost choices (continue vs restart, preview threshold); DecoderPolicy; InputMap parsing and the binding table; ResumeStore (save rules, finished deletion, atomic write, corrupt file recovery); ContentKey stable across rename; IINAWatchLater parsing with a fake folder; TimeFormat; Settings and State round trips.
- ReelEngine (on fixtures): format descriptions for each codec; Annex B conversion; NAL non-reference detection; open and first frame per fixture; exact seek returns the frame with the expected pts and its luma matches a sequential software decode (PSNR at least 35 dB) on sampled targets; audio timestamps continuous across buffers; Opus pre-skip and AAC priming handled; HDR10 colour keys present on decoded buffers; rotation reported.
- ReelUI: PlayerModel state transitions with a fake engine; ChromeVisibility timing with an injected clock; seek bar drag produces scrubs then one exact; remaining-time toggle; ShotRenderer produces non-blank images.

**reelctl** (headless, no window):
- `probe <file> [--json] [--build-info]`: streams, codecs, decoder choice, hardware support, keyframe count, duration.
- `decode-bench <file> [--decoder hw|sw|auto]`: fps and CPU seconds.
- `seek-bench <file> [--runs N] [--json]`: one resident engine. Measures first frame after open (fresh engine per run), keyframe seeks to random targets, exact seeks to worst-case targets (the frame before each next keyframe) and to random targets; reports p50/p95/max and checks every landed frame's pts. Latency ends when the target frame's `enqueue` on the video receiver returns `.enqueued` on a standalone display layer (the closest headless proxy for "on screen").
- `av-sync <file> [--json]`: decodes through the engine's audio and video paths, finds beep onsets (sample-accurate, from the engine's audio pts) and flash frames, reports max |beep - flash| over the file and after 10 exact seeks.

**Background screenshots.** Verified on this Mac: SwiftUI `ImageRenderer` renders the controller with `.regularMaterial`, SF Symbols and text in both light and dark from a plain command-line process, with no window, no `NSApplication` run loop, and the frontmost app unchanged. It does not render `NSViewRepresentable` content (so not the display layer) and rendered nothing for `.glassEffect`. Design that follows:
- The app binary has a shot mode: `Reel.app/Contents/MacOS/Reel --shot <scenario> --appearance light|dark --size 1280x720 --out <png>`. It never calls `NSApplication.run`, never creates an `NSWindow`, decodes the fixture frame with `FrameGrabber` (VideoToolbox to `CVPixelBuffer`, then `VTCreateCGImageFromCVPixelBuffer`), builds `PlayerSceneView` with that image as a SwiftUI `Image` in place of the layer, renders it at 2x with `ImageRenderer`, writes the PNG and exits.
- `PlayerSceneView` is the same view the window hosts; only the video surface differs (layer in the app, image in the shot).
- Scenarios: `empty`, `playing` (controller and title visible), `paused-osd` (volume OSD), `scrubbing` (hover pill and grown track). Each in light and dark.
- `scripts/shots.sh` runs each scenario as a direct exec of the bundle binary with a fresh `REEL_HOME` (no `open`, no LaunchServices), records `lsappinfo front` before and after, polls `scripts/winlist.swift` (CGWindowList by owner PID, no screen recording permission needed) for any on-screen window of that PID while it runs, and fails on either.

**Gates** (`scripts/check.sh`): deps (stamp), fixtures (stamp), `swift build -c release`, `swift test`, `swiftlint lint --strict`, license check via `reelctl probe --build-info`, `scripts/bundle.sh --release`, `codesign --verify --strict`, `plutil -lint`.

**Acceptance** (`scripts/accept.sh offline`): Haul's pattern (`record id status note`, results in `build/accept/<timestamp>/results.tsv`, exit 1 on any FAIL, a missing test counts as FAIL). Criteria are in the brief and section 16.

## 15. Visual design

- The video area is always black in both appearances. The chrome follows the system appearance through standard materials and semantic colours (`.primary`, `.secondary`, accent for the played track only). Nothing is forced dark.
- Typography: SF Pro throughout. Times 12 pt medium monospaced digits; hover pill 12 pt semibold; OSD 20 pt semibold rounded; title 13 pt semibold, centred in the title bar area, fading with the chrome; empty state 15 pt semibold.
- Spacing: controller padding 14 x 10, 18 pt between transport buttons, 16 pt minimum margin from window edges.
- Motion: chrome fade 0.22 s in, 0.35 s out; track grow spring 0.18 s; hover backgrounds 0.12 s; OSD 0.12 s in, 0.25 s out; controller drag follows directly with no animation; window resize for a new video animates 0.2 s keeping its centre. Reduce Motion: opacity only, 0.1 s.
- App icon: a simple generated icon (`scripts/make-icon.swift`) until a drawn one exists: a rounded square with a dark gradient and a white play glyph, nothing borrowed from IINA.
- Check the controller over pure white and pure black frames (the fixtures include both in the sync flashes).

## 16. Milestones

### M1: a fast, good-looking player for daily use

- `scripts/deps.sh`, `scripts/fixtures.sh`, the package scaffold and shared types.
- Engine: demux, keyframe index, packet store, hardware and software video, audio, A/V sync, scrub and exact seeks with keyframe preview, non-reference skipping, generation cancel.
- `reelctl` probe, decode-bench, seek-bench, av-sync.
- App: window, empty state, play/pause, seek bar with hover time, elapsed and remaining time, volume and mute, OSD, keyboard (M1 rows of section 10), scroll and click gestures, Open panel, drag and drop, file argument on launch, basic fullscreen, display sleep assertion, resume with IINA carry-over, Settings window.
- `scripts/bundle.sh` (signed with the Apple Development certificate by SHA-1 like Haul, bundle id `dev.sdusteric.reel`), background screenshots, `scripts/accept.sh offline`.
- Private GitHub repo `sdusteric/reel`, created in the first task, as the user asked.

Acceptance (each checked by a command):
1. All gates green: `scripts/check.sh` exits 0.
2. Seek speed: `reelctl seek-bench --json --runs 20` on the HEVC, AV1 and H.264 fixtures meets every threshold in section 7.6, and 100% of exact seeks land on the expected frame.
3. A/V sync: `reelctl av-sync` on both sync fixtures reports max |beep - flash| at most 20 ms sequentially and after 10 seeks.
4. Background screenshots: `scripts/shots.sh` produces 8 PNGs (4 scenarios x light/dark) at 2560x1440, non-blank, light and dark controller regions differ clearly, frontmost app unchanged, no on-screen window.
5. Behaviour tests present and passing: the required suites (ResumeStore, IINAWatchLater, SeekPlanner, KeyframeIndex, InputMap, PlayerModel, ChromeVisibility, OpenAndDrop) each have passing tests in `swift test` output.

### M2: complete IINA replacement

- Subtitles: libass, embedded text tracks, PGS and DVD bitmaps, external file discovery, GB18030 fallback, zho then eng preference, size 45 default, delay and position keys.
- Audio and subtitle track menus in the controller and the menu bar; video track cycling.
- Thumbnail preview on the seek bar: keyframe-only decode at open in the background (VT scaled to 480x270 BGRA, 200 per second on one session), cached per content key under `REEL_HOME/Caches`, manual keyframe packet feed for VP9.
- Next and previous episode in the folder (natural sort of video files in the same directory), Cmd+Right/Left and the controller buttons; auto-advance at the end. This needs folder read access, so the TCC usage strings land here.
- Playback speed with pitch preservation.
- VP9 hybrid decoder (software for long exact seeks, hardware for playback).
- Picture in Picture (`AVPictureInPictureController` with the sample buffer layer content source).
- Fullscreen polish: controller 56 pt from the bottom, menu bar and cursor hide with the chrome.
- Now Playing and media keys (`MPRemoteCommandCenter`, `MPNowPlayingInfoCenter`).
- Default-app document types: `CFBundleDocumentTypes` (Viewer, rank Default) for mp4, mov, mkv, webm, avi, flv, ts, m4v and the rest, `UTImportedTypeDeclarations` for mkv, webm, flv and others; the user sets Reel as default in Finder themselves.
- Cmd+S screenshot, A-B loop, window scale menu polish, music mode only if asked.

## 17. Risks

- Real files are heavier than the noise fixtures; real-world exact seeks will be slower than the bench. The keyframe preview is the mitigation, and M2 thumbnails add another.
- Requesting `420v`/`x420` from VideoToolbox may cost bandwidth at 4K60 versus the native compressed formats. If 4K60 playback drops frames, try the native formats and verify the layer accepts them.
- The 4 failed frames per run in the spike's VT bench were not explained. The engine test that compares seeked frames against software decode will catch real corruption.
- Audio device behaviour (Bluetooth, device switches, multichannel downmix) cannot be verified while the user is away and tests must stay silent. It is logged and left for the user to check.
- HDR on-screen output, PiP start and fullscreen cannot be verified without showing a window; they need a hands-on check by the user.
- `ImageRenderer` shots approximate the material blur; they check layout, type and appearance, not the exact blur.

## Decisions to review

All mine, made while the user was away.

- D1. Name Reel, bundle id `dev.sdusteric.reel`.
- D2. Swift + AppKit lifecycle, SwiftUI for overlay and settings content; not GPUI.
- D3. Own engine (FFmpeg demux and software decode, direct VideoToolbox, Apple renderers and synchronizer) instead of libmpv. The spike supports it: FFmpeg's hwaccel path, which mpv uses, was 3 to 7 times slower than direct VideoToolbox for full-GOP decode.
- D4. Own `VTDecompressionSession` and enqueue decoded frames, not compressed frames, into the display layer.
- D5. macOS 27 deployment target, to use the new receiver API; this Mac is the only target.
- D6. Statically linked minimal LGPL FFmpeg 9.0.2, libass 0.17.5, HarfBuzz, FriBidi, FreeType (FTL), dav1d, pinned by sha256; C libraries built for macOS 14.0 as verified.
- D7. No network features in M1 or M2 (no OpenSubtitles, no yt-dlp), even though the user had those IINA plugins on; Haul handles downloads.
- D8. SwiftPM only, no Xcode project; bundle assembled by script like Haul.
- D9. All audio decoded to LPCM in software; no compressed passthrough.
- D10. Cubic volume curve to match mpv; first-run volume 47.
- D11. Packet store 30 s / 192 MB behind, 20 s / 192 MB ahead; decoded queue 8 frames.
- D12. Keyframe preview during exact seeks predicted to take more than 150 ms; background exact seek after a 150 ms drag pause.
- D13. Non-reference frame skipping for H.264 and single-sub-layer HEVC before the seek target.
- D14. VP9 hybrid decoding deferred to M2; M1 reports VP9 seek numbers without thresholds.
- D15. `.regularMaterial` controller instead of Liquid Glass, because glass did not render in headless shots.
- D16. Background screenshots by `ImageRenderer` in a shot mode of the app binary, launched by direct exec, not `open -g` (the user's 3440x1440 display may be 1x, where Haul's `screencapture` route refuses to run, and the screen may be locked).
- D17. Resume keyed by a content hash (size + first and last 64 KiB), saved every 5 s and on every state change; IINA watch_later positions read as a fallback.
- D18. JSON files under `REEL_HOME` instead of `UserDefaults`.
- D19. Subtitle default size 45 on mpv's 720-line scale, GB18030 fallback for non-UTF-8 text subtitles (M2).
- D20. No test attaches an audio renderer unless `REEL_ALLOW_AUDIO=1`.
- D21. Seek thresholds set at roughly 1.3 to 2 times the measured direct VideoToolbox full-GOP time, and 2 to 3 times faster than the IINA-like baseline.
- D22. The private GitHub repo `sdusteric/reel` is created by the first build task, as the user asked; this design step was read-only apart from this document.
