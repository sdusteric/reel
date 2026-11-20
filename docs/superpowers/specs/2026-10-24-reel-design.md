# Reel design

Date: 2026-10-24
Status: M1 shipped. M2 built (tasks M2-1 to M2-7 landed on 2026-10-24); `scripts/accept.sh offline` passes all six M2 criteria and all of M1 (see "M2 status" in section 16). Earlier status: approved for M1 by the planner (the user is away and opted out of questions; every decision below is the planner's and is listed for review in "Decisions to review"). M2 design pass done on 2026-10-24 (sections 8, 9.3 to 9.12, 10, 15.2 and 16; mockups in `docs/mockup/`); its calls are D26 to D49. M3 design pass done on 2026-10-25 from a user-research pass (7.7 to 7.11, 9.13, 9.14, 11.1, 15.3, 16; mockups 19 to 27 in `docs/mockup/`); its calls are D50 to D68. M3 built on 2026-10-25 (tasks M3-1 to M3-7 landed, then two fix rounds); `scripts/check.sh` is green and `scripts/accept.sh offline` passed every M1 and M2 criterion and 9 of the 10 M3 criteria; the third fix round closed the open one (one AC-M3-5 file whose VP9 tile damage VideoToolbox decodes without an error) with a parse-only VP9 tile check held to 2% of a core (7.10, D69). Also for the user: untagged 720 x 480 now follows QuickTime (BT.709, 7.7); HLG images keep reference white at the PQ level, brighter than QuickTime's own HLG conversion (7.7, D53); real Dolby Vision fixtures with RPUs now exist and AVFoundation plays them (7.8); see "M3 status" in section 16.

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
- **Anything that phones home.** No network code. FFmpeg is built with `--disable-network`, there is no analytics and no crash reporter. The one exception, added after M2, is Sparkle 2 auto-update in the app target only (app-updates `CONTRACT.md`); it never starts in tests, shots, tools or with `REEL_NO_UPDATES=1`. A lint rule rejects `URLSession`, `NWConnection` and `Network` imports in `Sources/`. Section 13.

## 5. Supported formats

Containers (FFmpeg demuxers): mp4, m4v, mov (mov), mkv, webm (matroska), flv, avi, ts, m2ts, mts (mpegts), mpg, mpeg, vob (mpegps), m2v (mpegvideo), ogg/ogv, plus wav, mp3, aac, flac for audio-only files.

Video:

| Codec | Decoder | Notes |
|---|---|---|
| H.264 (avcC and Annex B) | VideoToolbox hardware | Annex B (ts) converted to length-prefixed NAL units |
| HEVC Main and Main10 | VideoToolbox hardware | hvcC; HDR10 and HLG colour carried in the format description |
| AV1 | VideoToolbox hardware when `VTIsHardwareDecodeSupported` (true on this M5), else dav1d | av1C from extradata |
| VP9 profile 0 and 2 | VideoToolbox hardware after `VTRegisterSupplementalVideoDecoderIfAvailable` | vpcC built from codecpar |
| MPEG-4 Part 2, MS-MPEG4 v3, FLV1 (Sorenson H.263), MPEG-2, VC-1 | libavcodec software | old avi and flv files, DVD (vob, mpg) and TV recordings (ts) |

Audio: everything goes through libavcodec and swresample to interleaved 32-bit float LPCM: AAC, AC3, E-AC3, DTS, TrueHD/MLP, FLAC, Opus, Vorbis, MP2, MP3, ALAC, PCM. Passthrough of compressed audio is not used **(my call)**: AudioToolbox has no DTS or TrueHD decoder, and one LPCM path is simpler to make sample-accurate.

Subtitles (M2): SRT, ASS/SSA, WebVTT, mov_text, PGS, DVD/VobSub, external files next to the video.

Interlaced video (field order from the stream, or per frame from libavcodec) is deinterlaced on the GPU before it is shown, at frame rate: the first field is kept, and lines of the other field are rebuilt from their neighbors where they comb (`Deinterlacer`). Progressive frames are not touched.

Known gaps: Dolby Vision profile 5 (single-layer IPT) shows wrong colours; from M3 Reel says so with a note instead of silently (7.8). Profile 8 plays as its HDR10 or HLG base layer. DTS-HD MA and TrueHD Atmos play as their core or bed channels. 4:2:2 and 4:4:4 content goes to the software path and is untested.

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
- Colour: always set `ColorPrimaries`, `TransferFunction`, `YCbCrMatrix`, `FullRangeVideo` from codecpar. When codecpar is unspecified (AV1 in mkv often is), software-decode one frame with libavcodec (2 to 9 ms) and read the frame's colour fields, mastering display metadata and content light level. If still unknown: SMPTE-C/601 up to 704 x 576 (both dimensions), BT.709 for anything larger, which is VideoToolbox's own guess for QuickTime (measured in 7.7; 720 x 480 is BT.709 there). HDR10: `MasteringDisplayColorVolume` (24 bytes, G B R order) and `ContentLightLevelInfo`.
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

### 7.7 HDR10 and HLG presentation (M3)

User research (section 16, M3) found that no Mac player is trusted with HDR: VLC 3 does not render it, IINA dims the whole screen on Apple Silicon, Infuse has Dolby Vision bugs. M3 makes HDR10 and HLG correct and quiet by handing presentation to the system and testing everything Reel controls with numbers.

**Who does what.**

- Reel decodes to 10-bit `x420` (VideoToolbox) or P010 (software, dav1d, VP9 hybrid) and makes sure every decoded `CVPixelBuffer` carries complete colour attachments: `kCVImageBufferColorPrimariesKey` (ITU_R_2020), `kCVImageBufferTransferFunctionKey` (SMPTE_ST_2084_PQ or ITU_R_2100_HLG), `kCVImageBufferYCbCrMatrixKey` (ITU_R_2020), and for PQ `kCVImageBufferMasteringDisplayColorVolumeKey` and `kCVImageBufferContentLightLevelInfoKey` when the stream has them. The hardware path gets these from the format description (7.3); the software path sets them on every pooled buffer with `.shouldPropagate`; AV1 and VP9 take colour from the first decoded frame when codecpar is unspecified (7.3). Per-frame HDR metadata is left to VideoToolbox (`PropagatePerFrameHDRDisplayMetadata`, default on).
- The `AVSampleBufferDisplayLayer` and the window server do the rest: EDR on the built-in XDR display and on external HDR displays, tone mapping to the current headroom (which changes with brightness and when the window moves to another display), and tone mapping to SDR on SDR displays. This is the path QuickTime and AVPlayer use, so Reel inherits their behaviour, including how macOS raises the backlight for EDR on the built-in display, rather than inventing its own **(my call)**. Reel does not render video with Metal and has no on-screen tone mapper.
- Reel sets one property: the display layer's `preferredDynamicRange` (`CALayer.DynamicRange`, macOS 26 and later; `wantsExtendedDynamicRangeContent` is deprecated in the macOS 27 SDK). The value comes from the pure `DynamicRangePlan` in ReelCore:

| Content | Setting "High dynamic range" | Display layer | Tag (9.13) |
|---|---|---|---|
| SDR (BT.709, BT.601, sRGB, unknown) | any | `.standard` | none |
| HDR10, HLG, Dolby Vision with an HDR base | Full (default) | `.high` | "HDR10", "HLG", "Dolby Vision" |
| same | Limited | `.constrainedHigh` | same |
| same | Off | `.standard` (the system tone-maps to SDR) | same, detail "SDR" |
| any HDR on a display whose potential headroom is 1.0 | any | as above (the system tone-maps) | detail "SDR" |

  The plan depends on the content and the setting only; the display changes only the tag detail and Video Info. So moving the window between displays never reconfigures the layer, and a headroom change (brightness, ambient light) never touches Reel at all.
- **No whole-screen dimming.** Reel never asks for more than the layer property above: no `NSScreen` brightness tricks, no EDR on SDR content, no EDR on the chrome. If the user still sees the desktop dim on some display, Limited (`.constrainedHigh`, "brightness is modulated to optimize for co-existence with other composited content") or Off is the fix, one popup away in Settings (11.1). The hands-on check below asks for exactly this comparison.
- **Chrome and subtitles stay at SDR white.** The subtitle `CALayer`, the hosting view of the SwiftUI chrome and every panel keep `preferredDynamicRange = .standard` (set explicitly, so a future default change cannot raise them), and their contents are untagged sRGB `CGImage`s with no headroom. White text is therefore SDR reference white whatever the video does. A test reads these properties back.
- **Mini player.** The mini player shows the same display layer and subtitle layer as the window (it borrows the surface), so HDR, EDR and the SDR-white subtitles need nothing extra there. The PiP frame compositor was removed with Picture in Picture (2026-10-26).

**Display state.** `DisplayRangeMonitor` (app target) reads `maximumPotentialExtendedDynamicRangeColorComponentValue`, `maximumExtendedDynamicRangeColorComponentValue` and `maximumReferenceExtendedDynamicRangeColorComponentValue` of the window's screen on `NSWindow.didChangeScreenNotification` and `NSApplication.didChangeScreenParametersNotification`, and polls the current value at 2 Hz only while Video Info is open **(my call; nothing else needs it, and polling costs wakeups)**. It feeds the tag and Video Info. The macOS "High Dynamic Range" switch for an external display shows up here as a potential headroom of 1.0 or more.

**Images Reel makes from HDR frames.** Screenshots (Cmd+S), thumbnails, the next-episode card image, Now Playing artwork and shot mode all go through one `HDRToneMapper` in ReelEngine: `CIImage(cvPixelBuffer:)` (linear, unclamped, 1.0 = reference white), drawn into 8-bit sRGB by ColorSync's PQ to SDR conversion, the one AVFoundation uses. As built, this replaced the `CIToneMapHeadroom` plan: that filter (and `CISystemToneMap`, the same at headroom 1.0) puts reference white at sRGB 188, under the 190 floor below, so it is kept only to simulate an EDR display's headroom and as a reported reference (`headroomCurveLumas`). For PQ the result is byte-identical to `AVAssetImageGenerator` (QuickTime) on the same frame: neutral patches 0, 2, 15, 63, 186, 229, 250, 255, 255, 255 for 0 to 10000 nits in both. **HLG does not match QuickTime** (measured 2026-10-25 on `hlg_ramp_hevc.mp4`): Apple's own HLG to SDR conversion puts reference white (signal 0.75) at 146 (Core Image) or 155 (`AVAssetImageGenerator`, neutral patches 0, 22, 55, 98, 155, 208, 255), under the 190 floor of the rules below and under the 225 floor of AC-M3-9. `HDRToneMapper` therefore writes HLG frames as PQ first, which gives 0, 16, 61, 137, 229, 253, 255: it passes both floors but is about 74 codes brighter than QuickTime at reference white. Every other Apple HLG to SDR method was measured on the same frame (2026-10-25, `CGContextDrawImageApplyingToneMapping` from a half-float HLG image into 8-bit sRGB): default and reference-white-based 188, ITU-R recommended 146 (154 with `kCGUse100nitsHLGOOTF`), `none` 124 (and it clips), image-specific, EXR gamma and the adaptive gain curve draw nothing for this image. None reaches 190, let alone 225. **Resolved (third fix round): the AC-M3-9 floor wins, and the images still use Apple's tone mapping.** HLG frames are converted to PQ (the BT.2100 HLG to PQ transcode for a 1000-nit display, which puts signal 0.75 at 203 nits as BT.2408 specifies) and then tone-mapped by ColorSync's PQ to SDR conversion, the same Apple curve and the same output QuickTime gives for PQ. HLG reference white therefore lands at 229, exactly where QuickTime and Reel put PQ reference white (203 nits, 229). QuickTime's own HLG path (155) disagrees with its PQ path by 74 codes for the same reference white, and it would fail AC-M3-2's 190 floor as well as AC-M3-9's 225 floor, both of which are fixed. Matching it would mean a darker image for HLG than for the same scene in PQ, so Reel does not. The on-screen picture is not affected: the display layer and the window server tone-map it as for QuickTime (D50). Subtitles are drawn on the screenshot after tone mapping, at full white. Reel writes no HDR PNG or gain-map image **(my call: an SDR PNG looks the same everywhere it is pasted)**. The thumbnail session decodes HDR keyframes to `x420` at 384 x 216 and tone-maps them; SDR keyframes keep the BGRA path of M2.

**SDR colour follows ColorSync, as QuickTime does.** SDR frames keep the colour their stream describes (attachments from the stream; untagged SD, up to 704 x 576, as SMPTE 170M and anything larger as BT.709), the display layer's colour space is never overridden, and nothing adjusts saturation or gamma. `reelctl color <file> --frame N [--decoder hw|sw] [--screenshot png] --json` compares Reel's sRGB output for frame N (matched by index in display order: FFmpeg's packet times and AVFoundation's edit-list timeline differ by the B-frame delay on an ffmpeg mp4) with `AVAssetImageGenerator` on a 6 x 4 grid of 16 x 16 means; the fixtures `sdr/bars709_h264.mp4`, `sdr/bars709_untagged_h264.mp4` and `sdr/bars601_sd_h264.mp4` are flat bars (75% bars, greys, 100% primaries and secondaries, six Macbeth patches), so every grid point is a flat patch. Measured 2026-10-25: the tagged and untagged HD files match QuickTime exactly (difference 0 on all 24 patches, hw and sw). The SD boundary is VideoToolbox's, which is what QuickTime and `AVAssetImageGenerator` use for an untagged stream (`ColorInfoGuessedBy = VideoToolbox` on the decoded buffer), measured on untagged H.264 and HEVC: 176 x 144, 320 x 240, 640 x 480, 704 x 480 and 704 x 576 get SMPTE-C and BT.601; 706 x 480, 712 x 480, 720 x 480, 720 x 576, 704 x 578, 640 x 600 and 640 x 720 get BT.709. The first SD fixture was 720 x 480, which QuickTime reads as BT.709 while Reel then read every frame under 720 lines as SMPTE 170M, so saturated bars differed by up to 70 codes (100% cyan: Reel 70, 253, 255 against QuickTime 0, 233, 255) and the two halves of AC-M3-8 could not both hold. Reel now uses VideoToolbox's rule (`VideoColor.isStandardDefinition`), so it matches QuickTime for every untagged size, and `sdr/bars601_sd_h264.mp4` is 704 x 480 (an SD size, written with the BT.601 matrix), which both read as SMPTE 170M: every bar is within 1 code of `AVAssetImageGenerator`, hw and sw. **Consequence for the user to review:** an untagged 720 x 480 or 720 x 576 file (a DVD-sized rip) is now shown as BT.709, as QuickTime shows it; mpv and IINA would use BT.601 for it. A file AVFoundation cannot read (a Dolby Vision record in the sample description, 7.8) has no reference and `reelctl color` says so.

**Offline tests** (all headless, on generated fixtures, section 14):

- Fixtures `hdr/pq_ramp_hevc.mkv` and `.mp4`, `hdr/hlg_ramp_hevc.mkv` and `.mp4` (lossless x265 Main10), `hdr/pq_ramp_av1.mkv` (container colour tags removed, so the frame probe must find them) and `hdr/pq_ramp_vp9.webm` (profile 2), plus `hdr/sdr_ramp_h264.mp4`. Each frame is a row of flat neutral patches at known levels (PQ: 0, 0.1, 1, 10, 100, 203, 400, 1000, 4000, 10000 nits; HLG: signal 0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0) and three BT.2020 primaries at reference white, written as raw 10-bit YUV by `scripts/make-ramp.py` and encoded by Homebrew ffmpeg. PQ files carry mastering metadata (P3 D65, 1000 nits) and MaxCLL 1000, MaxFALL 400.
- `reelctl hdr <file> [--decoder hw|sw] [--display sdr|xdr|external|headroom=X] [--setting full|limited|off] [--screenshot png] --json` reports: the content classification, the Dolby Vision record, the attachments on a decoded buffer, the decoded 10-bit Y code at each patch centre against the generated code, the `DynamicRangePlan` for the simulated display and setting, and the tone-mapped 8-bit sRGB value of each patch through `HDRToneMapper`.
- Pass rules: decoded patch codes within 2 of the generated codes on HEVC (4 on AV1 and VP9), on both decoders; all colour attachments present and correct, including MDCV and CLL bytes for PQ; tone-mapped neutral patches strictly increasing up to the clip point with at least 7 distinct values, 0 nits at most 3, the 203-nit patch (and HLG 0.75) between 190 and 250, R, G and B of each neutral patch within 3 of each other. (A PQ frame shown without tone mapping would put the 203-nit patch at 148, so the rule catches the most common bug.)
- Layer configuration: `DynamicRangeLayerTests` builds `PlayerContentView` without a window, applies plans and reads back `preferredDynamicRange` on the display, subtitle and chrome layers.
- Shot mode: the `hdr-badge`, `video-info` and `hdr-sdr` scenarios use the PQ ramp, so the background screenshot is checked numerically too (`shot-stats --patch`).

**Hands-on check for the user** (cannot be automated without a visible window):

1. Built-in XDR display, brightness at about 50%: open `build/fixtures/hdr/pq_ramp_hevc.mp4` in Reel and in QuickTime Player side by side. The 1000-nit patch should be visibly brighter than the white menu bar in both; the desktop, menu bar and Reel's controller must not dim in Reel more than in QuickTime.
2. Drag the window to an SDR external display and back: the tag gains and loses "SDR", the 400 and 1000 nit patches stay distinct on the SDR display, nothing flashes.
3. An external HDR display with HDR on in System Settings: same as step 1.
4. Settings, High dynamic range, Limited and then Off: highlights get dimmer, the picture stays correct.
5. Cmd+S on the ramp: the PNG looks like the SDR display in step 2.

### 7.8 Dolby Vision (M3)

- Detection: the Matroska (`BlockAdditionMapping`) and MP4 (`dvcC`, `dvvC`, `dvwC`) demuxers already export the configuration record as `AV_PKT_DATA_DOVI_CONF` coded side data. `DolbyVisionProbe` reads it into `MediaInfo.dolbyVision` (profile, level, RPU, EL and BL present flags, `dv_bl_signal_compatibility_id`). `reelctl probe --json` prints it.
- Policy (`DolbyVisionPolicy`, pure, in ReelCore), by compatibility id:

| Compatibility id | Typical profiles | What plays | Shown as |
|---|---|---|---|
| 1 | 8.1, 7 (MEL/FEL base) | HDR10 base layer, PQ, with its MDCV and CLL | tag "Dolby Vision", Video Info "Playing the HDR10 base layer" |
| 6 | 7 (Blu-ray) | HDR10 base layer | same |
| 4 | 8.4 | HLG base layer | tag "Dolby Vision", Video Info "Playing the HLG base layer" |
| 2 | 8.2, 9 | SDR base layer | tag "Dolby Vision", Video Info "Playing the SDR base layer" |
| 0 | 5, 10.0 | the decoded base, which is IPT and not displayable correctly | tag "Dolby Vision 5" with a warning glyph, note (9.13) |

- The RPU (NAL type 62) and enhancement layer (type 63) are passed through untouched; VideoToolbox and libavcodec ignore them for the base layer. The non-reference skipping of 7.5 never classifies types 62 and 63 as droppable VCL units (a test covers it). `dvh1` and `dvhe` sample entries use the `hvcC` from the configuration and the HEVC codec type, `dav1` uses `av1C`.
- **Profile 5 (my call): note only in M3.** Showing it correctly needs the RPU reshaping and IPT to RGB conversion applied per frame (libplacebo does this; FFmpeg 9 parses the RPU into `AVDOVIMetadata` in libavcodec, LGPL), which means a GPU stage between decode and the display layer. That is a large piece of work for a format the user's library may not contain (section 1 lists BluRay x265 and YouTube downloads; profile 5 comes from streaming WEB-DL releases). Whether VideoToolbox would apply profile 5 itself for a `dvh1` session is unknown and cannot be tested without a real profile 5 sample, which no generator can make. M3 therefore plays the base with the note and keeps a probe: `reelctl probe --dovi-session <file>` creates a `kCMVideoCodecType_DolbyVisionHEVC` session, decodes 10 frames and reports the output buffers' attachments and mean chroma, so the user can run it once on a real file (hands-on) and decide whether M4 needs the reshaping path.
- Fixtures: `hdr/dv81.mp4`, `hdr/dv81.mkv` (the PQ ramp with a `dvvC` record, profile 8 level 6, compatibility 1), `hdr/dv84.mp4` (the HLG ramp, compatibility 4) and `hdr/dv5.mp4` (sample entry `dvh1`, `dvcC`, profile 5, compatibility 0), made by `scripts/make-dovi.py`, which inserts the record into the `stsd` entry of an ffmpeg-written MP4 (moov after mdat, so no chunk offsets move) and remuxes the mkv from it. The pixels are the ramps, so 8.1 must decode to the same codes as `pq_ramp_hevc.mp4`.
- **What the fixtures do not show** (measured 2026-10-25): they are not real Dolby Vision streams. They carry no RPU (ffprobe finds no frame with RPU side data in `dv81.mp4` or `dv5.mp4`), and AVFoundation rejects `dv81.mp4` whenever its `dvvC` atom is in the format description (VideoToolbox status -12704 on all 48 frames, `AVAssetImageGenerator` returns no image; with `dvvC` stripped the PQ ramp decodes exactly). Reel's decode path passes only `hvcC`, which is why it works. Passing AC-M3-3 shows that Reel ignores the container record and decodes the HEVC base; it does not show that real 8.1 or profile 5 files play correctly. **Fixtures with real RPUs** (third fix round): `scripts/make-dovi-rpu.c`, a generator compiled by `fixtures.sh` against Homebrew's FFmpeg (never linked into Reel), decodes a ramp, attaches `AVDOVIMetadata` to every frame (identity reshaping: two pivots, a first-order polynomial with coefficient 1.0 at log2 denominator 23; level 0 display management values for BT.2020; L1, L5 and L6 with 1000 and 400 nits) and re-encodes with `libx265 -dolbyvision 1` (lossless, plus the VBV settings x265 requires for Dolby Vision), which writes an RPU NAL unit (type 62) per access unit and the configuration record. It makes `hdr/dv81_rpu.mp4` (PQ base, `hvc1`, `dvvC`), `hdr/dv84_rpu.mp4` (HLG base) and `hdr/dv5_rpu.mp4` (`dvh1`, `dvcC`, full range, colour tags unspecified; the pixels are the PQ ramp, not IPTPQc2, so only the signalling is real), all level 3. Measured 2026-10-25 (`DolbyVisionRPUTests`):
  - AVFoundation accepts all three (every frame decodes in `AVAssetReader`, `AVAssetImageGenerator` returns images), where it rejects the record-only fixtures. For 8.1 its image is identical to the plain PQ ramp's (neutral patches 0, 2, 15, 63, 186, 229, 250, 255, 255, 255), which is what Reel shows: with an identity reshaping, QuickTime and Reel's HDR10 base playback agree.
  - Reel: probe reports 8.1, 8.4 and 5 with their compatibility ids; `reelctl hdr` decodes 8.1 and 8.4 to the ramp codes exactly (error 0, hw and sw) with tag "Dolby Vision" and no note; profile 5 gets tag "Dolby Vision 5", the note and the warning.
  - VideoToolbox's Dolby Vision HEVC session (`reelctl probe --dovi-session`) decodes the profile 5 file without a failure and attaches each frame's RPU to the output buffer (`DolbyVisionRPUData`), but returns the base unreshaped (mean chroma equals the plain HEVC session's). The record-only `dv5.mp4` fails with -12704.
  - `AVAssetImageGenerator` on the profile 5 file does apply Dolby Vision processing: neutral patches 2, 8, 26, 71, 178, 219, 243, 254 and green 230 instead of 255, against 0, 2, 15, 63, 186, 229, 250, 255 for the same pixels as PQ. So Apple's pipeline handles profile 5 from the RPU attachment after decode; a later milestone could try the `dvh1` session with the attachment on the display layer instead of a GPU reshaping stage. Profile 5 stays a note in M3, as the user decided.
  - Still not shown: a non-identity RPU (real content), where QuickTime applies the RPU's dynamic mapping and Reel plays the static HDR10 base. That comparison stays hands-on check 7 (section 16). `FrameGrabber.referenceImage`, the only AVFoundation reference path, refuses a track whose sample description carries `dvcC`, `dvvC` or `dvwC` instead of returning nothing or a wrong frame.

### 7.9 Energy (M3)

Research shows people judge a player's battery use against QuickTime (VLC measured 43 Energy Impact against QuickTime's 7 to 10). Reel already uses hardware decode for every common codec; M3 makes sure it does nothing when nothing changes, and measures it.

What runs in each state (`EnergyPolicy`, pure, in ReelCore; the engine and app read it):

| | Playing, visible | Paused | Playing, occluded | Ended or no file |
|---|---|---|---|---|
| Video decode and enqueue | yes | none after the shown frame (and the 8-frame decoded queue is not refilled) | stops 1 s after occlusion | none |
| Demux read-ahead | to the 20 s limit | finishes the current fill, then the thread blocks on a condition (no polling) | audio needs only | none |
| Audio decode | yes | none | yes | none |
| Time events to the UI | 10 Hz chrome visible, 1 Hz hidden | one on each state change and seek, none periodic | 1 Hz (Now Playing) | none |
| Subtitle renders | while an event is active or due within 1 s | none (one render on seek) | none | none |
| Thumbnail generation | yes (utility QoS) | continues while the pointer moved in the window in the last 10 s, then suspends | suspended | suspended |
| Display sleep assertion and App Nap activity | held | released | released | released |

- **Occlusion** (my call): `NSWindow.occlusionState` without `.visible` (fully covered, minimised, another Space) for 1 s while playing stops video decode and enqueue (while the mini player is up, the panel is the window that counts, since the main window is ordered out); audio keeps playing. When the window becomes visible, the engine runs an exact seek to the synchronizer's current time with the keyframe preview, so a picture appears within the scrub budget and the exact frame within 300 ms for the HEVC fixture. This saves the whole video decode for people who listen with the window hidden; the cost is a short preview on return.
- Every dispatch timer gets a leeway of 10% of its interval so the system can coalesce wakeups. In Low Power Mode (`ProcessInfo.isLowPowerModeEnabled`) thumbnail generation stops after the coarse pass (every 8th position).
- No display link runs during playback; the subtitle renderer is a dispatch timer (8.6), and the rules above gate it. The mini player's snap after a drag runs one until the spring settles (well under a second).
- The VP9 tile check (7.10) runs only while VP9 video is fed to VideoToolbox, so never while paused or occluded, and is held to 2% of one core on average by a `CheckBudget`. `energy-bench` reports its share (`vp9TileCheck`) and `--no-tile-check` turns it off for a comparison.

**Measurement.** `reelctl energy-bench <file> --mode play|paused|occluded --seconds 20 [--warmup 5] --json` runs one `PlaybackEngine` headless with no audio renderer (the synchronizer follows the host clock) and a standalone display layer. If that layer does not consume frames at the clock rate off screen, the bench uses a `ClockedVideoSink` that releases frames at their presentation time and says so in the report. It reads `proc_pid_rusage(RUSAGE_INFO_V6)` for its own process before and after the window: CPU time, interrupt wakeups, package idle wakeups, billed energy, instructions. Hardware decode runs in a `VTDecoderXPCService` process, so the bench also records the PIDs of `VTDecoderXPCService` processes that appeared after its session was created and reads their usage the same way (same user, no privileges; reported as `xpc` and left out when not found). Engine counters (frames decoded, packets read, subtitle renders, time events, thumbnails decoded) are reported per window. `occluded` mode sets the engine's occluded flag after warm-up and, at the end, clears it and reports the resync latency.

Budgets (the bench's own process, 20 s window after 5 s warm-up, measured on the M5 Pro; the M3 build records the M2 baseline in section 16 first, and a budget that the baseline already beats by more than 3 times is tightened to 2 times the measured value):

| Mode | Fixture | CPU (of one core) | Wakeups per second | Counters |
|---|---|---|---|---|
| play | `hevc10_1080p24.mkv` | at most 4% | at most 150 | frames decoded within 2% of 24 x 20 |
| play | `av1_2160p60.mkv` | at most 10% | at most 300 | frames within 2% of 60 x 20 |
| paused | both | at most 0.3% | at most 5 | 0 frames decoded, 0 packets read, 0 subtitle renders, 0 time events |
| occluded | `hevc10_1080p24.mkv` | at most 2% | at most 60 | 0 video frames decoded after the first second; resync at most 300 ms |

**M2 baseline** (recorded 2026-10-25 by the M3 fix round: the M2 engine at commit 448f066 with M3's bench ported to it, same 20 s window after 5 s warm-up, hardware decode, no audio renderer; two rounds interleaved with the M3 bench, while Spotlight indexing used about two cores, so these are upper values). Play `hevc10_1080p24.mkv`: CPU 1.48 and 3.72%, 114 and 132 wakeups per second. Play `av1_2160p60.mkv`: CPU 3.51 and 4.95%, 117 and 120 wakeups per second. Paused, both files: CPU 0.40 to 0.94%, 65 to 97 wakeups per second (M2 polled while paused). M2 has no occluded mode. No budget is beaten by more than 3 times (the closest are play CPU, 4 / 1.48 = 2.7 and 10 / 3.51 = 2.85), so every budget above stands as written. A baseline taken on a quiet machine may be lower and could tighten the two play CPU budgets; that run is left to the user. The M3 build in the same rounds: hevc play 3.42 and 1.59% CPU, 88 and 74 wakeups per second; av1 play 4.83 and 5.51%, 75 and 81; paused 0.003 to 0.005% and 0.6 to 0.7 wakeups per second.

**Hands-on check for the user** (QuickTime is a GUI app and cannot run in a test): open `build/fixtures/h264_1080p30.mp4` and `build/fixtures/hdr/pq_ramp_hevc.mp4` in QuickTime Player and in Reel in turn, play each for 2 minutes in a window, and read Activity Monitor's Energy tab ("Avg Energy Impact" after 2 minutes) or run Instruments with the Power Profiler template. Target: Reel at most 1.5 times QuickTime on the same file, and Reel at or near 0 while paused. Record the numbers in section 16.

### 7.10 Damaged and odd files (M3)

Reliability decided the research reviewer's choice of player more than picture quality. M3 makes Reel predictable on files that are cut short, corrupt, or unusual, and proves it with a generated corpus.

- **Open failures** are classified into `MediaProblem` (ReelCore) with fixed copy (9.14): `.notMedia` (no demuxer matched), `.cutShort` (a known container header, then end of file before the first video or audio packet), `.noPlayableStream`, `.unsupportedCodec(name)`, `.unreadable(reason)` (I/O error, permission), `.volumeGone(name)` (the path is under `/Volumes/<name>` and that volume is not mounted). Each has a title, a one-sentence explanation and a technical detail line with FFmpeg's error string.
- **Corrupt data during playback**: a packet that fails to decode, or a decoder error event from the receiver, does not stop playback. As built, three more signals count as damage: a frame libavcodec decoded with concealed errors (`decode_error_flags` or `AV_FRAME_FLAG_CORRUPT`; H.263 and MPEG-4 Part 2 hide a damaged block instead of failing), a Matroska cluster whose CRC-32 element does not match (FFmpeg's demuxer skips cluster checksums; WebM clusters from ffmpeg carry none), and a packet FFmpeg marks corrupt. When video resumes at a keyframe after damage, that keyframe starts a new decode run as a seek does, so the RASL pictures of an HEVC CRA (x265's default open GOP), which reference the skipped GOP, are skipped instead of failing and sending the feeder back to waiting GOP after GOP (one 4 KB overwrite in a 20 s open-GOP file cost 349 of 480 frames before, 24 after). Video waits for the next keyframe (the decoder is flushed if it reports an error state), audio drops the bad packet and re-anchors its running timestamp (7.4). One OSD per damaged region, at most one per 10 s ("Skipped damaged video at 12:04", or "audio"), and `damagedFrames` in Video Info. Damage inside VP9 tile data is invisible to every decoder Reel runs (measured 2026-10-25 on `corpus/vp9.overwrite50.webm`, whose 4 KB lands in the 36 KB packet at 0.792 s, a hidden alt-ref frame): VideoToolbox, libavcodec and libvpx (the reference decoder, through Homebrew's ffmpeg) all decode it without an error, and WebM from ffmpeg has no CRC-32. **VP9 tile check (as built in the third fix round, D69).** The VP9 spec's exit process for the boolean decoder requires the bits after a tile's last symbol to be zero, and damaged tile data leaves the decoder somewhere else. `scripts/patches/ffmpeg-vp9-tile-check.patch` (applied by `deps.sh`, LGPL like the rest of FFmpeg) adds two things to libavcodec's VP9 decoder: with `err_recognition` containing `AV_EF_BITSTREAM` it checks every tile's padding and fails the frame with `AVERROR(EBADMSG)`, and with `skip_idct` at `AVDISCARD_ALL` it runs only the existing parse pass of its two-pass mode (pass 1: modes, motion vectors, coefficients and probability adaptation) and reconstructs nothing. `VP9TileCheck` (ReelEngine) runs such a decoder, single-threaded, beside VideoToolbox on the feeder: every packet about to go to the hardware decoder is parsed first, and a damaged one is skipped with the decoder waiting for the next keyframe, counted and reported exactly like a frame VideoToolbox failed. The check starts only at a keyframe that is output (never on a seek's pre-roll, so seek times do not change), pauses until the next keyframe whenever a packet is skipped, decoded in software or after a seek, never skips the seek target itself, and turns itself off for a file whose first keyframe already fails the padding rule (an encoder that does not zero it; libvpx does). Its CPU time is a `CheckBudget` token bucket: 2% of one core earned per second of playback, 250 ms allowance at open, a check starts only at a keyframe with credit and stops mid-GOP when it owes more than 100 ms. Measured 2026-10-25: no false positive on `vp9.webm`, `hdr/pq_ramp_vp9.webm`, `vp9_2160p60.webm` and nine libvpx variants (good and realtime deadlines, two-pass with alt-ref, 10-bit, 4:4:4 with tile rows, lossless, frame-parallel and error-resilient, CRF, 20 Mbit/s CBR); 80 of 80 random 4 KB overwrites found in two 720p files; the damaged packet of `overwrite25`, `50` and `75` found, nothing else. Parse cost about 1 ms per packet at 640 x 360 and 1.5 Mbit/s, 0.74 ms at 1080p30 and 3 Mbit/s, 3.7 ms at 4K60 and 25 Mbit/s (53% of a software decode). In `energy-bench`, 20 s of play after 5 s warm-up: `vp9_2160p60.webm` checked 49 of 1200 packets for 1.9% of a core (process CPU 7.96% against 6.19% with `--no-tile-check`); a 30 s 1080p30 3 Mbit/s file checked 318 of 600 packets for 2.7% (the allowance left after warm-up counts in the window). So VP9 up to about 2 Mbit/s is checked completely and higher rates by whole GOPs as the budget allows. The corpus `vp9.overwrite50.webm` now plays through with 5 damaged frames. Three consecutive failures after a keyframe on the hardware path still switch to software at the next keyframe (7.3).
- **Cut-short files** (`.cutShort` that opened, or any file whose index promises more than the data holds): the demuxer records the last readable presentation time (`dataEnd`) when it hits end of file early, and for MP4 compares the last sample's file offset with the file size at open. The seek bar keeps the header duration and draws the tail faint (9.14); times count to `dataEnd`; a seek past it lands on the last frame with the OSD "No data after 38:02"; the end of data is treated as the end of the file for resume and auto-advance.
- **Drive disconnected**: a read error with `ENXIO`, `EIO` or `ENOENT` while the file's volume is no longer in `/Volumes` pauses, keeps the last frame (dimmed), saves the resume entry and shows the card (9.14). Reel listens for `NSWorkspace.didMountNotification`; when a volume with that name mounts and the file at the same path has the same content key, it reopens at the saved time and plays if it was playing. Try Again does the same at once.
- **Odd but valid files** must play: mid-stream resolution change (H.264 SPS change in TS: a new format description at the next keyframe), audio layout change (re-create the ASBD, flush audio), MPEG-TS timestamp wrap at 2^33 (unwrap in the demuxer), negative or large start times, variable frame rate, a single-frame file, audio-only files with cover art, odd dimensions (hardware refuses, software plays), 4:2:2 and 4:4:4 (software path; listed as untested in M1), streams without a keyframe index (intra refresh: the planner falls back to the stream start and the keyframe preview is skipped), 64 tracks, and a 240-character file name with CJK and emoji.
- **No crash, no hang**: every FFmpeg call that can fail has its return value checked (most already do); every blocking wait in the engine has a timeout that turns into a classified error; a watchdog in the engine fails an open that has not produced a result in 10 s with `.unreadable("timed out")`. As built, the blocking part of the open (FFmpeg's probe, the external subtitle scan) runs on its own thread and the watchdog on a Dispatch timer, not on the Swift cooperative pool: an open stuck on a dead drive holds no pool thread, and a busy pool cannot hold the watchdog past its deadline (in `swift test` the parallel decode suites kept the pool full for up to 4 s, and the open gave up after 3.3 to 4.4 s instead of 0.3 s).

**Corpus and soak.** `scripts/make-corpus.py` (stdlib only, run with `python3 -I`, fixed seed list) writes `build/fixtures/corpus/` from 8 small base fixtures (2 s each: H.264 mp4 with moov at the end and at the front, HEVC mkv, AV1 mkv, VP9 webm, TS, AVI, FLV): truncations at 1, 10, 50 and 90% of the bytes, the first 4 KB only, a 4 KB random overwrite at 25, 50 and 75%, bit flips at a rate of 1e-4 with 3 seeds, a zero-filled middle 10%, and the two halves swapped; about 100 files, under 150 MB. `scripts/fixtures.sh` adds `odd/` with the files listed above plus a 0-byte file, a text file named `.mp4`, 1 MB of random bytes named `.mkv` and a ProRes file (not in the LGPL decoder list, so `.unsupportedCodec`).

`reelctl soak <file|dir> [--seed S] [--ops N] [--seconds N] [--asan-expected] --json` runs each file in its own child process (`reelctl soak-one`, tracked by PID, stopped by PID after 30 s), so a crash is a signal exit in the report instead of the end of the run. The child opens the file, plays at rate 4 for a few seconds on the host clock, runs N seeded operations (scrub, exact seek including before 0 and past the end, frame steps, track switches, speed changes, subtitle toggles, close and reopen), closes, and reports: outcome (played or the `MediaProblem` class), operations completed, the longest operation, damaged frames, `dataEnd`, peak RSS, and open file descriptors and threads after close compared with before open.

### 7.11 Small M3 additions

- **Subtitle visibility** (v, already bound in M2): the OSD names the key ("Subtitles Hidden, press V to show"), and visibility resets to shown when the next file opens, so a stray press never carries over **(my call; IINA removed its default binding because users lost subtitles to it)**.
- **Add Subtitle File** gets Shift+Cmd+O (Reel's choice; IINA has no default) in the Subtitles menu and the panel tooltip. Dropping a subtitle file on the window already works (M2).
- **Output device**: System Default (follows Sound settings) or a chosen device, stored by `AudioDeviceUID` with its name in `state.json`. The list comes from Core Audio (`kAudioHardwarePropertyDevices`, devices with output streams; reading it needs no permission and makes no sound), refreshed on the device-list property listener. The choice applies through `AVSampleBufferAudioRenderer.audioOutputDeviceUniqueID`. If the chosen device is gone at open or disappears while playing, playback continues on the system default with the OSD "Audio: MacBook Pro Speakers" and the choice is kept for when it returns. In Settings and as Audio, Output Device. `reelctl devices --json` lists the devices without attaching any renderer.

## 8. Subtitles (M2)

The user watches with Chinese subtitles first and English second, at IINA size 45, and many of their files carry fansub ASS tracks that are bilingual (Chinese line over a smaller English line). Subtitles are therefore a first-class output of the engine, rendered by libass for text and decoded to bitmaps for PGS and DVD, and they must stay readable on any frame, survive seeks without a blank gap, and never slow a seek down. The M2 look is in 15.2 and the mockups `docs/mockup/png/07` to `09`.

### 8.1 Sources and decoding

- libass 0.17.5 with the CoreText font provider (verified: Chinese, kana and fallback fonts render; first frame 46 ms, then 24 ms; `changed == 0` lets us skip re-blending). One `ASS_Library` per app, one `ASS_Renderer` per player, one `ASS_Track` per selected text track.
- Embedded text tracks (ASS/SSA, SubRip, WebVTT, mov_text): packets decoded with `avcodec_decode_subtitle2`; `rect.ass` goes to `ass_process_chunk` with the packet's pts and duration, the decoder's `subtitle_header` to `ass_process_codec_private`. The FFmpeg build already has these decoders (`scripts/deps.sh`).
- Embedded bitmap tracks (PGS `hdmv_pgs_subtitle`, DVD `dvd_subtitle`): decoded to `AVSubtitleRect` PAL8 bitmaps, converted to premultiplied BGRA `CGImage`s (palette expanded once per rect), positioned on the decoder's canvas (`width`/`height` from the codec context, 1920x1080 for BluRay) and scaled to the video rect. A PGS display set with no objects clears the screen; an `end_display_time` of 0 or `UINT32_MAX` means "until the next display set".
- External files: same folder as the video, plus `Subs/` and `Subtitles/` subfolders one level down (common in release packs). Matched by stem, case-insensitive, exact or `stem.` prefix (`movie.srt`, `movie.en.srt`, `movie.zh-Hans.srt`, `Movie.EN.forced.srt`, `movie.chs.ass`, `movie.cht&eng.ass`). Remaining dot tokens parse as language (ISO 639-1/2, BCP 47, and the fansub tags `chs`, `sc`, `gb` for Simplified and `cht`, `tc`, `big5` for Traditional) and flags (`forced`, `sdh`, `hi`, `default`). Supported: `.srt`, `.ass`, `.ssa`, `.vtt`. `.sub` only with a sibling `.idx` (VobSub) is listed but **not supported in M2** (FFmpeg's `vobsub` demuxer is not in the build); `.sup` likewise (no `sup` demuxer). Both appear in the menu as disabled items with the reason, so the user knows the file was seen **(my call)**.
- External text files are read whole at selection (they are small), decoded through the same libavcodec decoder as embedded tracks, and held in memory.
- Text events for the whole file: a seek lands on a keyframe, so an embedded line that started before that keyframe would be missing until the next line. To avoid that, after open a `SubtitlePrefetcher` opens a second `AVFormatContext` on the file with every stream except the text subtitle streams set to `AVDISCARD_ALL` and reads it through at background priority, feeding every text event into its track. Matroska skips discarded blocks without reading them, so this costs roughly one walk over the cluster headers (well under a second for a 4 GB episode on SSD). Until it finishes, events come from the main demuxer as it reads. Bitmap tracks are not prefetched (they are large); after a seek, the display set active at the target is found by reading back from the keyframe to the previous PGS epoch start, at most 10 s **(my call)**.

### 8.2 Track choice and labels

- Preference: the first track whose language matches `zho`/`chi`/`zh*`, then `eng`/`en*`, preferring non-forced, then the container default flag; this mirrors the user's IINA `subLang zho,eng`. Among Chinese tracks, Simplified (title or tag containing `简`, `chs`, `sc`, `Hans`, `GB`) before Traditional. When an external file and an embedded track match equally, **the external file wins**: people add external files when the embedded one is wrong or missing **(my call)**.
- No match: subtitles start Off; the subtitle button stays enabled so Add Subtitle File is one click away.
- Forced-only tracks are chosen automatically only when the audio language matches the subtitle language and no full track exists.
- Label: language name from `Locale` for the ISO code, plus script or region when known ("Chinese (Simplified)", "Chinese (Traditional)", "English"). Second line: the container title when it says something the language does not ("简英双语", "Commentary", "Signs & Songs"), then flags ("Default", "Forced", "External: file name" with the name middle-truncated). Format tag: `ASS`, `SRT`, `VTT`, `TX3G` (mov_text), `PGS`, `VobSub`. The same rule labels audio tracks with codec and channels ("E-AC-3 5.1", "AAC 2.0", "TrueHD 7.1", "Opus 2.0").
- The choice (track identity by language, title and codec), subtitle delay and size are saved in the resume entry, and carried to the next episode in the folder by matching language and title, then language alone (section 9.8).

### 8.3 Charset

- Text files and embedded text tracks are tried as UTF-8 (UTF-16 by BOM). If libavcodec reports invalid UTF-8, the track is reopened with `sub_charenc` and `sub_charenc_mode=pre_decoder`: Big5 first when the file name or track title says Traditional (`cht`, `tc`, `big5`, `zh-Hant`, `zh-TW`, `zh-HK`), else GB18030 (the user reads Chinese; GBK srt files are common) **(my call)**. If the second charset also fails, the track opens as Latin-1 and the OSD says "Subtitle encoding not recognised". The detected charset is shown on the track's second line ("GB18030") and in `reelctl subs --json`.

### 8.4 Style

- Text tracks without their own styling (SubRip, WebVTT, mov_text) use Reel's default style, applied with `ass_set_selective_style_override` (font, size, colours, outline, shadow, margins) on a 720-line reference (`PlayResY` 720):
  - Font `PingFang SC`, weight Medium (500). It covers Latin, Simplified and Traditional Han, so one family serves Chinese and English lines alike. A track whose language, file name or title says Traditional uses the same face as `PingFang TC`, Hong Kong and Cantonese tracks `PingFang HK`, Macau `PingFang MO`, so each script gets its own glyph forms.
  - On macOS 27 PingFang exists only in `PingFangUI.ttc` with `hvgl` outlines, which FreeType (and so libass) cannot read. Reel writes the Medium instance of PingFang SC, TC, HK and MO from CoreText's glyph paths (all quadratic, same glyph ids, same advances, the original GSUB) into one TrueType collection, registers it with libass through `ass_add_font`, and caches it under `REEL_HOME/Caches/fonts` (about 22 MB, built in under a second on first use). If that fails, the families fall back to Hiragino Sans GB and Heiti TC.
  - Accepted Chinese faces (decision after the M2 build): the documented fallback list is PingFang when FreeType can read it (the rebuilt collection above), otherwise Hiragino Sans GB. Hiragino Sans GB is accepted as the default Chinese face whenever PingFang cannot be read, because macOS 27 ships PingFang only as `hvgl` outlines that FreeType and libass cannot load directly, and a rebuild can fail (for example when CoreText withholds the paths). Either face must draw the line with 0 missing glyphs; AC-M2-2(b) checks for a face from this list.
  - Size 45 (6.25% of the video height: 45 pt in a 720 pt tall video, 67.5 pt at 1080, 90 pt on the 1440 pt fullscreen display). This is the user's IINA `subTextSize` on mpv's 720-line scale **(my call; the mapping from IINA's value is my reading of mpv's scale, unverified against IINA on screen)**.
  - Primary white `#FFFFFF`; outline black, 2.5 on the reference (border style 1, about 3.75 px at 1080); shadow black at 60%, offset 1.4 down, blur 0.6 (`\blur` on the outline edge so it reads soft, not stamped). No box. This replaces M1's "1.5 pt outline": at size 45 a 1.5 outline disappeared on sand and snow in the mockup (`png/08`).
  - Italic and bold from SRT tags kept; SRT colour tags kept.
- ASS/SSA tracks keep their own styles and fonts (fansub bilingual tracks style the English line themselves). Only the user's size factor (Shift+G / Shift+F, `ass_set_font_scale`) and position change apply. If a style names a font that is not installed, libass falls back through CoreText (PingFang SC for Han, Hiragino Sans for kana, Apple SD Gothic Neo for Hangul) and logs it once per font.
- Bitmap tracks are drawn as authored; the size factor does not apply to them **(my call)**; position changes and the controller lift do.
- Size and position changes: Shift+G / Shift+F change the scale by 10% (shown as the IINA-style number, 45 to 50 to 55, in the panel and OSD); r / R and t move bottom subtitles up and down by 1% of the video height. Both are saved per file in the resume entry, the size also as the default for new files when changed from the panel.

### 8.5 Placement

- Bottom margin 40 on the 720 reference (5.6% of the video height), centred, maximum line width 90% of the video width (libass wraps).
- Text tracks without positioning render over the whole window, not only the video rect (`ass_set_use_margins`), so in fullscreen with a 2.39:1 film the lines sit in the black bar under the picture; ASS tracks and bitmap tracks keep the video rect, because their positions are authored against it **(my call)**.
- **Lift above the controller.** While the controller is visible and its frame intersects the band where bottom-aligned lines are drawn, those lines move up so their bottom edge sits 12 pt above the controller's top edge. Only bottom-aligned events without `\pos` or `\move` move (libass `ass_set_line_position`); signs and positioned karaoke stay. Bitmap subtitles whose bounding box is in the bottom third move as one image. The lines snap up as the chrome starts to appear and snap back after the chrome has finished fading out; nothing animates (15.2: the lift runs on every reveal, the lines are text being read, and an animation would mean a libass render per frame) **(my call; IINA does not lift, YouTube does)**. If the user dragged the controller away from the bottom, nothing moves.
- Fullscreen uses the same rules on the display's size (mockup `png/15`).

### 8.6 Rendering and timing

- The subtitle clock is the synchronizer's time minus the subtitle delay. A `CADisplayLink`-paced render (at most once per display frame, normally 30 Hz while text is changing, idle otherwise) calls `ass_render_frame` at the window's pixel size. `changed == 0` skips everything; `changed == 1` (same bitmaps, moved) reuses the blended image with a new position; `changed == 2` re-blends.
- Blending: the `ASS_Image` list is composited into one premultiplied BGRA bitmap covering the union of the images' rects (the dirty rect, typically 1500 x 160 px for two lines at 1080), then set as `contents` of a `CALayer` above the display layer, with `contentsScale` equal to the window's backing scale. Bitmap subtitles use the same layer.
- Delay: Shift+Z / Shift+X step 0.5 s, Alt+Shift+Z / Alt+Shift+X step 0.1 s, Shift+C resets (IINA's bindings, section 10). Delay applies to text and bitmap tracks alike.
- Seeking: on `.scrub(t)` the subtitle shown is the one at t (from the prefetched events), so scrubbing shows the right line next to the keyframe preview. On `.exact(t)` it updates when the target frame lands, never before, so text and picture change together.
- Next and previous line (Shift+Right / Shift+Left): an exact seek to the start of the next or previous text event of the selected track (`ass_step_sub`), using the prefetched events.
- Screenshots (Cmd+S) include the subtitles, composited at the video's native resolution (IINA's default `screenshot` includes them).
- Mini player: subtitles render at the panel's pixel size with a floor, so a size 45 line stays as large as it is at a 208 pt tall layer (`setSubtitleMinimumHeight`, mini player design section 5). No frames are copied.

### 8.7 Fallbacks and failures

- A track whose decoder cannot open is listed as disabled with the reason ("Japanese, PGS: decoder failed"). A malformed ASS event is skipped and logged; the rest of the track plays.
- A font with missing glyphs falls back through CoreText per character; `reelctl subs` counts libass "glyph not found" messages so the acceptance test can require zero for the Chinese fixtures.
- If libass fails to initialise, subtitles are disabled for the session with one OSD ("Subtitles unavailable") and a log line; playback continues.
- The subtitle pipeline never blocks video or audio: rendering runs on its own serial queue, and a render that is still running when the next one is due is skipped, not queued.
- No tracks and no external files: the subtitle panel shows "No subtitles in this file" in the track area, with Add Subtitle File below.

## 9. Window and controls

All sizes in points.

### 9.1 Window

- `NSWindow`, `styleMask [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable]`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `isMovableByWindowBackground = true`, `tabbingMode = .disallowed`, background black. AppKit app lifecycle (`NSApplicationDelegate`), SwiftUI for the overlay and settings content **(my call)**: it gives direct control of the window, the layer and focus.
- Content view: a layer-backed `PlayerContentView` (black) containing the `AVSampleBufferDisplayLayer` (`videoGravity = .resizeAspect`) and, above it, an `NSHostingView` with the SwiftUI chrome (controller, OSD, title).
- One window. Opening a new file replaces the current one (IINA `alwaysOpenInNewWindow = 0`).
- First open: size to the video's display size (after pixel aspect and rotation), scaled down to fit 80% of the screen's visible frame, centred. On the user's 5K display (2560x1440 points, Retina) a 1080p video opens at 1920x1080 points (80% of the visible frame is about 2048x1130, so it fits unscaled); a 4K video opens at 1920x1080 too (scaled to fit). Later opens keep the window's centre and width, set the height from the new aspect, and clamp to the screen. `contentAspectRatio` = the video aspect, so resizing keeps it. The frame is saved in `state.json`.
- Empty state (no file): 720x450, black, a 60 pt rounded tile (white 10% fill, 0.5 pt white 14% stroke) with a play glyph (22 pt, white 62%), then "Open a video" (15 pt semibold, white 78%) and "Drop a file here or press ⌘O" (12 pt, white 50%, the key in a small keycap chip), centred. The colours are fixed because the area is always black. The whole window is a drop target.
- Fullscreen: native `toggleFullScreen(_:)` with `.fullScreenPrimary`. M1 supports it without polish; the controller keeps its fractional position. M2 polish (mockup `png/15`):
  - The controller keeps its stored x fraction but its bottom edge is fixed at 56 pt from the screen bottom (the stored y applies only to windows). Same size as in a window (600 pt wide on the 2560 pt display): pointer precision does not change with the screen, so the controls keep their physical size **(my call)**.
  - `presentationOptions` `[.fullScreen, .autoHideMenuBar, .autoHideDock]`; the menu bar and the cursor hide with the chrome (cursor through `NSCursor.setHiddenUntilMouseMoves`), and the menu bar can still be revealed by moving to the top edge.
  - The title shows at the top centre over the scrim, and "Ends at 22:47" (wall-clock end time at the current speed, 12 pt medium, white 72%) at the top right, 24 pt in. Fullscreen only: in a window the remaining time is enough, but in fullscreen the system clock is hidden **(my call)**.
  - Entering and leaving fullscreen keeps the subtitle size relative to the video (size 45 is 6.25% of the video height, so 90 pt on the 1440 pt display).
- Mini player (section 9.9): a floating, non-activating panel that borrows the window's video surface; the window is ordered out while it is up.
- Display sleep: `IOPMAssertionCreateWithName(PreventUserIdleDisplaySleep, "Reel is playing video")` while playing, released on pause, close and quit.

### 9.2 Chrome visibility

- The traffic lights, title and controller share one `chromeVisible` state.
- Shown on pointer movement of 2 pt or more inside the window, on any key that changes playback (shown for the auto-hide period), and while paused with the pointer inside the window.
- Hidden after 2.5 s without input while playing, and at once when the pointer leaves the window, playing or paused, so burned-in subtitles are never covered (user request 2026-10-25). Never hidden while the pointer is over the controller, a drag is in progress or a panel is open. The tracking area is `.activeAlways` so the exit arrives when another app is in front.
- The cursor hides with the chrome (`NSCursor.setHiddenUntilMouseMoves(true)`) only when the pointer is over the video.
- Fade in 0.16 s on the shared ease-out token (at least 90% opaque by 60 ms, 15.2), fade out 0.35 s ease-in. Traffic lights fade through `standardWindowButton(_:)?.animator().alphaValue` in the same transaction. With Reduce Motion: opacity only, 0.1 s.

### 9.3 Controller

- A SwiftUI view inside the hosting view (not a separate window).
- Shape: rounded rectangle (continuous corners), corner radius 24, height 80, width 480 (min 360, max 560, never more than 70% of the window width), padding 14 horizontal, 12 vertical, 6 pt between the two rows.
- Material: `.regularMaterial` in both appearances, 0.5 pt inner stroke (white 12% in dark, black 8% in light), two shadows: a contact shadow (radius 1.5, y 1, opacity 0.22) and an ambient one (radius 28, y 10, opacity 0.28). Not Liquid Glass **(my call)**: a headless `ImageRenderer` test on this Mac rendered `.regularMaterial` correctly in light and dark but rendered nothing at all for `.glassEffect`, so glass would break the background screenshots that are our UI check. Revisit in M2 if a capture path for glass exists.
- Position: stored as fractions of the window (x of the centre, y of the bottom edge from the window bottom), default x 0.49, y 0.11 (the user's saved IINA position). Draggable by any area that is not a control; follows the pointer with no animation; clamped to keep 16 pt from every edge. Double-click on an empty area resets it.
- Top row: elapsed time (left), seek bar (fills), remaining time (right, `-12:34`, default because the user has `showRemainingTime` on). Clicking the right label toggles remaining and total; persisted.
- Bottom row: left, volume icon (click toggles mute) plus a 72 pt slider that widens to 120 on hover; centre, back 10 s, play/pause (32 pt hit circle, 22 pt glyph), forward 10 s; right, fullscreen. M2 adds previous/next, subtitle, audio, speed and PiP buttons.
- **M2 layout** (mockup `png/01`; exact values in 15.2):
  - Width becomes `clamp(0.45 x window width, 440, 600)`, still at most 70% of the window: 576 pt in a 1280 pt window, 600 pt in the user's usual 1920 pt window and in fullscreen.
  - Left cluster: volume button, 6 pt, slider 72 pt that widens to 104 pt on hover (was 120; the centre cluster needs the room).
  - Centre cluster, centred in the row: previous episode, 16, back 10, 20, play/pause, 20, forward 10, 16, next episode (216 pt). Transport spacing goes from 22 to 20 pt.
  - Right cluster, flush right: speed label button (min 36 pt wide), 6 pt, subtitles, audio, mini player, fullscreen (28 pt hit targets, no gaps; the glyphs are 17 pt so the visual gap is 11 pt).
  - Previous and next are hidden when the file is alone in its folder, and the transport re-centres; previous is disabled (55%) on the first episode and next on the last (mockup `png/18`).
  - Below 568 pt of controller width the controller drops previous, next and the mini player button (they stay in the menus and keys); below 480 pt it also drops the audio button and the speed label. Priority from first kept to first dropped: play/pause, back and forward 10, fullscreen, volume, subtitles, audio, speed, next, previous, mini player.
  - Subtitle glyph: `captions.bubble.fill` while a subtitle track is on, `captions.bubble` while off. Audio: `waveform`. Mini player: `pip.enter`, and `pip.exit` in the accent colour while the mini player is up; tooltip "Mini Player, ⌃⌘P". Speed: the current rate as text ("1×", "1.5×", 13 pt semibold rounded, monospaced digits); when the rate is not 1 it turns accent on an accent 16 to 22% capsule so a changed speed is never missed.
  - Every button has a tooltip naming the action and its key ("Subtitles, Ctrl+Cmd+S" spelled with the system glyphs).
- Times: `.system(size: 12, weight: .medium).monospacedDigit()`, primary at 85%. Hours shown only when duration is 1 h or more.
- Icons: SF Symbols, medium weight, drawn at 14 pt (play 18 pt) so the glyphs fill the 17 pt (play 22 pt) boxes of the mockup, `.primary` at 90%, 55% disabled. Hit targets at least 28 pt; hover background `Color.primary.opacity(0.1)` circle fading in over 0.12 s; press feedback is a 0.94 scale over 0.1 s on pointer-down (none with Reduce Motion). Transport buttons are 22 pt apart. Play/pause swaps with `.contentTransition(.symbolEffect(.replace))`.

### 9.4 Seek bar

- Track 4 pt tall, grows to 8 pt on hover (spring, 0.18 s). Unplayed: primary 18%. Stored-in-memory range (the PacketStore window): primary 40%. Played: accent colour. Thumb: 12 pt circle, visible on hover and drag only.
- Hover pill above the track: time under the pointer in 12 pt semibold monospaced digits, on the same material with a soft shadow (radius 8, y 3), centred on the pointer and kept inside the ends of the bar. It sits 36 pt above the track. It follows x with no animation and fades in over 0.1 s. M2 adds a thumbnail above the time.
- **M2 thumbnail** (mockup `png/05`, `png/06`): when a thumbnail exists for the hovered time, the pill becomes a 12 pt radius container with 4 pt padding holding a 192 x 108 pt image (8 pt radius, height from the video aspect, clamped 80 to 144 pt) and the time on a 22 pt row under it. Its bottom edge sits 8 pt above the controller's top edge, it is centred on the pointer and clamped 16 pt inside the window (not the bar), so it can overhang the controller's ends. The image is the stored thumbnail of the last keyframe at or before the hovered time, the same picture a scrub would show. It shows on hover and during a drag. When no thumbnail exists yet for that region, the M1 time pill shows alone; when one arrives under a resting pointer, the image fades in over 0.12 s.
- **Thumbnails** (engine, section 16 M2): generated in the background after open from keyframes only, at most 400 per file (the keyframe at or before each of 400 evenly spaced times, duplicates dropped), coarse to fine (every 8th first) so the whole bar has coverage within the first second. A second `MediaSource` and its own `VTDecompressionSession` (destination attributes 384 x 216 BGRA, VideoToolbox scales) run at utility priority and pause while a seek is in flight. Setup (open, format description, session) ends with one synchronous decode of the first keyframe, which pays the new session's first-frame cost (18 ms for the 1.27 MB H.264 fixture keyframe) inside the 150 ms setup budget; that frame becomes the first keyframe's thumbnail, so nothing is decoded twice. VP9 keyframes are fed packet by packet to the supplemental decoder. Each image is JPEG-encoded (quality 0.75, about 12 KB) into one pack file per content key under `REEL_HOME/Caches/thumbnails/`, evicted oldest-first above 500 MB.
- **A-B loop marks:** while a loop is set, A and B show as 3 x 14 pt accent capsules on the track, and the range between them is tinted accent at 16 to 22% (mockup `png/12`).
- Drag sends `.scrub(t)` on every move (coalesced in the engine); release sends `.exact(t)`. Click without drag sends `.exact(t)`.
- A resume tick (2 pt wide, primary 50%) marks the saved position when the file was resumed.

### 9.5 OSD

- Top-left, 20 pt from the edges (below the title scrim while the chrome shows), a 17 pt symbol (speaker level, mute, resume) at 70% beside 20 pt semibold rounded text, on the controller material, corner radius 14, padding 16 x 10, soft shadow (radius 12, y 4). Seeks show text only.
- Shown for volume ("Volume 52"), mute, seeks from the keyboard ("12:04 / 1:02:33"), frame steps, and resume ("Resumed at 23:10", with a "Start Over" button that stays for 5 s).
- Appears with a 0.12 s fade and scale 0.96 to 1, stays 0.9 s after the last update, fades out over 0.25 s. Repeated updates change the text in place without re-animating.
- If an exact seek has not landed after 400 ms, a small progress ring appears next to the time in the OSD.
- M2 messages (mockups `png/10` to `png/13`), same component; numbers use monospaced digits and signs are always shown:
  - Speed: `gauge.with.dots.needle.67percent`, "Speed 1.5×" (two decimals only when needed: "Speed 1.21×").
  - Subtitle delay: `captions.bubble.fill`, "Subtitle Delay +0.5 s"; audio delay: `waveform`, "Audio Delay -0.1 s"; reset shows "Subtitle Delay 0.0 s".
  - Subtitle size and position: "Subtitle Size 50", "Subtitle Position 2%".
  - Track cycling from the keyboard: the new track's label ("Subtitles: Chinese (Simplified), ASS", "Audio: Japanese, AAC 5.1", "Subtitles Off").
  - A-B loop: `repeat`, "Loop from 31:04" (A set), "Loop 31:04 to 32:10" ("to" at secondary weight), "Loop Off". File loop: `repeat.1`, "Loop File On" / "Loop File Off".
  - Screenshot: `camera`, "Screenshot Saved" with a "Show" button (same style as Start Over, stays 3 s) that reveals the file in Finder. No sound.
  - Next or previous episode from the keyboard: the episode name (stem up to the episode token, "Northern Line S02E06").

### 9.6 Pointer and gestures

- Single click on the video: toggle pause, delayed 250 ms to allow a double click. Double click: toggle fullscreen.
- Two-finger horizontal scroll: seek. Continuous scroll sends scrubs (1 s of media per 8 pt of scroll, my default) and an exact seek when the gesture ends **(my call)**. Vertical scroll: volume, 1 step per 6 pt. Natural scrolling is respected.
- Drag on the video moves the window. Right click: context menu with Open, Play/Pause, Show in Finder. M2 adds Subtitles and Audio submenus (the same items as the menu bar), Speed, Take Screenshot and Enter Mini Player. In the mini player the menu is Play/Pause, Back to Window, Close Mini Player and the Subtitles, Audio and Speed submenus, and scrolling does nothing.
- M2: mouse back and forward buttons go to the previous and next episode (IINA's `MBTN_BACK` / `MBTN_FORWARD`).

### 9.7 Track and speed panels (M2)

- Mockups `png/02` (subtitles), `png/03` (audio), `png/04` (speed), `png/18` (no subtitles). SwiftUI views in the hosting view, not `NSMenu` and not `NSPopover`: they share the controller's material, render in the background screenshots, and can show two-line rows with format tags **(my call)**. The menu bar carries the same items as native menus (9.11), so keyboard and VoiceOver users have the standard path.
- Anchored to their button: horizontally centred on it and clamped 16 pt inside the window, bottom edge 10 pt above the controller's top edge. One panel at a time; the button shows the hover circle while its panel is open.
- Subtitle panel, 320 pt wide: header "Subtitles" with the track count; Off; one row per track (embedded first in container order, then external files); separator; Delay stepper (0.1 s steps; Alt-click 0.5 s); Size stepper (5 steps on the 45 scale); separator; Add Subtitle File (opens an `NSOpenPanel` filtered to srt, ass, ssa, vtt). Rows: 22 pt check column, label 13 pt medium, optional second line 11.5 pt, format tag right-aligned. Rows are at least 30 pt tall (42 with a second line). More than 9 tracks: the list scrolls inside a maximum height of 60% of the window, with the selected row scrolled into view.
- Audio panel, same width and rows; tag = codec and channels; Delay stepper at the bottom (audio delay is applied by offsetting audio timestamps against the synchronizer, so it never re-decodes).
- Speed panel, 264 pt wide: header "Speed"; a segmented row of 0.5, 0.75, 1, 1.25, 1.5 and 2 (26 pt tall, selected segment accent with white text); a Fine stepper in 0.05 steps showing two decimals. Range 0.25 to 4. Above 2 the engine may drop video frames to keep up; audio keeps its pitch (`.timeDomain`).
- Dismissal: click outside, Esc, the button again, or choosing a track (the track panels close on choice; the speed panel stays open so the stepper can be pressed repeatedly). Keyboard inside a panel: Up and Down move, Return chooses, Esc closes.
- Choosing a track applies within one frame: a subtitle switch re-renders at the current time from the prefetched events; an audio switch flushes and re-primes audio at the current time without moving the picture (section 16 M2, engine task).

### 9.8 Episodes and auto-advance (M2)

- The episode list is the playable video files in the same folder as the open file, excluding hidden files and AppleDouble `._` files, sorted with a natural sort (`localizedStandardCompare`, which orders "E2" before "E10" and handles "第2集" before "第10集"). Rebuilt on every open and when the folder changes (FSEvents on that one folder while it is open).
- Previous and next: Cmd+Left and Cmd+Right, the controller buttons, the media keys and the mouse side buttons. Next on the last file and previous on the first do nothing (the button is disabled).
- Carry-over: the next episode inherits speed (for the session), subtitle and audio track choice by language and title, subtitle delay and size if they were changed for this file, and the volume. Resume still wins if the next file has its own entry.
- **Auto-advance** (mockup `png/14`): when playback reaches the end and a next file exists, the last frame stays, the chrome stays visible, the play button becomes Replay (`arrow.counterclockwise`), the next-episode button turns accent, and a card appears 12 pt above the controller with its right edge on the controller's right edge (16 pt inside the window if that would overflow). The card is 360 pt wide, 20 pt radius, 12 pt padding: a 128 x 72 pt thumbnail of the next file (its first keyframe after 0:30, decoded once, so the cold open is not given away **(my call)**), with a 34 pt countdown ring and a play glyph over it; "Next Episode" and "in 3 s" on the first line; the episode name on the second (the file stem up to the SxxEyy or Exx token, dots and underscores turned into spaces, else the stem tail-truncated); Cancel and Play Now (accent) at the bottom right.
  - Countdown 5 s **(my call)**. Play Now, a click on the thumbnail or Return start the next file at once; Cancel or Esc removes the card and stays on the last frame. A pointer moving over the card pauses the countdown; it resumes when the pointer leaves.
  - No card when file loop is on (the file restarts), when an A-B loop is set, or when the next file cannot be opened (it is skipped and the one after is tried, up to 3, with an OSD naming the skipped file).
  - The resume entry of the finished file is deleted as in M1 (less than 30 s from the end).

### 9.9 Mini player (replaces Picture in Picture, 2026-10-26)

Designed and specified in `2026-10-26-reel-mini-player-design.md` (mockups `png/28` to `png/34`); that document is the source of truth for it. In short:

- Apple's Picture in Picture was removed: on macOS 26.4 and later it copies a sample buffer layer at 1:1 (FB22411168), and even with the crop worked around, AVKit placed its panel at the window's size and jumped it to the corner with no animation.
- `MiniPlayerPanel` is a non-activating, floating panel on every Space and over fullscreen apps. Clicking it never activates Reel; the keys work after Cmd+Tab, and media keys always.
- The window's `VideoSurfaceView` (display layer and subtitle layer) moves between a slot in the window's scene and a slot in the panel; the engine sees only a size change and a subtitle floor. The window is ordered out while the mini player is up and never resized.
- Default size fits a 480 x 360 box (480 x 270 for 16:9), smallest 256 x 192, largest half the visible frame, 20 pt from the corner, bottom right by default. A drag snaps to the nearest corner (a flick lands where it was thrown); edges and pinch resize. Corner, box scale and display are saved in `state.json`.
- Enter and leave are one 0.3 s move on the shared ease-out between the window's video area and the corner; with Reduce Motion, 0.15 s fades.
- Close pauses and orders the window in behind other apps; Back to Window, a double click and a Dock click bring it back and activate Reel. A failure card, closing the file or closing the window leave the mini player at once.

### 9.10 Now Playing and media keys (M2)

- `MPNowPlayingInfoCenter` while a file is open: title = episode name (9.8) or the stem, duration, elapsed time, playback rate, and the current thumbnail as artwork. Updated on play, pause, seek settle, rate change and every 5 s, never on every time tick. Cleared on close, so Reel stops claiming the media keys when nothing is open.
- `MPRemoteCommandCenter`: play, pause, toggle play/pause, next track and previous track (next and previous episode), change playback position (exact seek), skip forward and back 10 s. Media keys reach Reel through these, so they also work while Reel is in the background, which is how macOS media keys behave.

### 9.11 Menu bar (M2)

Native `NSMenu`s, mockup `png/17`. Items with a Command or Control shortcut show it; plain-key bindings stay out of the menus as in M1 (the content view handles them, so they never fire twice).

- Playback: Play/Pause; Forward 5 Seconds, Back 5 Seconds; Next Frame, Previous Frame; separator; Next Episode (Cmd+Right), Previous Episode (Cmd+Left), Auto-Advance to Next Episode (checkmark, on); separator; Speed submenu (Double Cmd+], Half Cmd+[, Faster Alt+Cmd+], Slower Alt+Cmd+[, Normal Cmd+\, then the presets with a checkmark); separator; Set Loop Start / Set Loop End / Clear Loop (one item whose title follows the state, Cmd+L), Loop File (checkmark, Shift+Cmd+L).
- Video: Half Size, Actual Size, Double Size, Fit to Screen (Cmd+0 to 3); Enter Full Screen (Ctrl+Cmd+F); Enter Mini Player / Exit Mini Player (Ctrl+Cmd+P); Video Track submenu and Next Video Track (Ctrl+Cmd+V, disabled with one video track); Take Screenshot (Cmd+S); Show Screenshots in Finder.
- Audio: the audio tracks with a checkmark; Next Audio Track (Ctrl+Cmd+A); Volume Up, Volume Down, Mute (Cmd+/); Increase Audio Delay, Decrease Audio Delay, Reset Audio Delay (disabled at 0).
- Subtitles: Off and the subtitle tracks with a checkmark (disabled items for unsupported external files, with the reason as a tooltip); Next Subtitle Track (Ctrl+Cmd+S); Add Subtitle File; Show Subtitles (checkmark); Delay submenu (Increase, Decrease, Reset); Size and Position submenu (Larger, Smaller, Move Up, Move Down, Reset).

### 9.12 Screenshot, loops and document types (M2)

- Cmd+S saves the current frame at the video's native size, with subtitles, as PNG to `~/Pictures/Reel/<stem> <hh-mm-ss>.png` (`REEL_SCREENSHOTS` overrides the folder; without it, a set `REEL_HOME` puts screenshots in `REEL_HOME/Screenshots`, so tests and tools with a temp home never write to ~/Pictures). Taken from the last landed decoded frame (`FrameGrabber.image(from:)`), so it never waits for a decode. No sound, no flash; the OSD confirms.
- A-B loop (Cmd+L): first press sets A at the current time, second sets B, third clears. Reaching B issues an exact seek to A, which is a store hit and lands in one GOP decode. B before A swaps them. File loop (Shift+Cmd+L): at the end, exact seek to 0 instead of ending; disables auto-advance while on.
- Default app: `CFBundleDocumentTypes` with role Viewer and rank Default for mp4, m4v, mov, mkv, webm, avi, flv, ts, m2ts, mts, ogv and the audio types; `UTImportedTypeDeclarations` for the types macOS does not declare (`org.matroska.mkv`, `org.webmproject.webm`, `com.adobe.flash-video`, `public.avi` where missing). The user sets Reel as the default player in Finder themselves; Reel never calls LaunchServices to claim it.
- Folder access: the episode list and external subtitles need to list the file's folder. Reel is not sandboxed, so macOS asks once per protected location (Documents, Downloads, Desktop, removable volumes). Info.plist carries `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSDesktopFolderUsageDescription` and `NSRemovableVolumesUsageDescription` ("Reel lists the other videos and subtitle files in the folder of the video you open."). If access is denied, the episode buttons hide and only embedded subtitles are offered; nothing else breaks. Tests and shots never trigger the prompt: they only list folders inside the repo's `build/fixtures` (or a `mktemp` dir), from the agent's shell, which already has access to them.

### 9.13 Dynamic range tag, Video Info and the Dolby Vision note (M3)

Mockups `png/19` to `png/22`.

- **Tag.** After the title in the title bar, 8 pt gap, a tag names the content's dynamic range: "HDR10", "HLG", "Dolby Vision", "Dolby Vision 5". SDR files have none. 18 pt tall, radius 5, padding 0 x 7, 10.5 pt semibold with +3% tracking, white 88% on white 12% with a 0.5 pt white 28% ring (fixed colours: it always sits on the black title scrim). When the picture is tone-mapped to SDR (setting Off, or a display with potential headroom 1.0) a detail follows at 500 weight, white 62%: "SDR". Profile 5 adds an 11 pt warning glyph (`exclamationmark.triangle.fill`, system yellow). The tag fades with the title and the chrome. The title truncates in the middle before the tag shrinks.
- The tag is a button: hover background white 20%, tooltip "This display shows standard dynamic range, so the HDR picture is tone-mapped to fit it." when tone-mapped, else "High dynamic range. Click for details."; click toggles Video Info.
- **Video Info** (Cmd+I, the key IINA uses for its Inspector; also Video, Video Info, and the tag). A panel on the panel material, 344 pt wide, radius 16, padding 6, at the top right, 20 pt from the right edge and 48 pt from the top (under the title scrim). Header "Video Info" 13 semibold with the key on the right at tag opacity. Rows are a two-column grid (key 92 pt at secondary opacity, value at primary 88%, 12 pt, monospaced digits), grouped by separators: Video (codec, profile, size, frame rate) and Decoder; Range (with a second line for Dolby Vision saying which layer plays), Colour (primaries, transfer, range), Mastering and Light level (PQ only); Display (name, HDR or SDR) and Headroom ("3.2× now, 16× at most" with a 4 pt meter); Audio; Frames (dropped, damaged). Values update in place at most twice a second; nothing animates. Esc, Cmd+I or a click outside closes it. It is read-only: no copy button, no tabs.
- **Dolby Vision profile 5 note.** On open, in the OSD position (9.5), the OSD component in a two-line variant: warning glyph (system yellow in dark, `#b25000` in light for contrast on the light material), "Dolby Vision profile 5 can't be shown correctly" (15 semibold), then "Reel plays the picture without its Dolby Vision colour data, so colours look wrong, often green or purple. Profile 8 files play correctly." (12 regular, secondary), then Show Info and OK capsules. It stays until OK, Esc or 10 s, whichever is first, and is shown once per file per session. Playback is not blocked. Max width 452 pt.

### 9.14 Failure and damage states (M3)

Mockups `png/23` to `png/26`. These replace M1's plain error line in the empty state.

- **Failure card** (open failed, drive gone). Centred in the video area, on black (open failed) or on the last frame dimmed to 38% brightness and 70% saturation (drive gone): the 60 pt tile of the empty state with a 28 pt glyph (`doc.badge.exclamationmark`-style for files, `externaldrive` for drives), 18 pt, title 15 semibold white 86%, file name 12 medium white 56% middle-truncated to 520 pt, 12 pt, explanation 13 regular white 72% at most 46 characters per line, 8 pt, detail 11 regular white 50%, 20 pt, capsule buttons 26 tall (secondary white 14%, primary system blue). Fixed colours, as the video area is always black. Copy:

| Problem | Title | Explanation | Buttons |
|---|---|---|---|
| `.cutShort` | This file can't be played | The file ends before its first video frame. It may still be downloading, or the copy was cut short. | Show in Finder, Open Another File… |
| `.notMedia` | This file can't be played | Reel doesn't recognise this as a video or audio file. | Show in Finder, Open Another File… |
| `.noPlayableStream` | This file can't be played | The file has no video or audio that Reel can play. | Show in Finder, Open Another File… |
| `.unsupportedCodec(name)` | This file can't be played | The video uses \(name), which Reel can't decode. | Show in Finder, Open Another File… |
| `.unreadable(reason)` | This file couldn't be read | macOS reported a read error. The disk may have a problem, or Reel may not have access to this folder. | Try Again, Open Another File… |
| `.volumeGone(name)` | “\(name)” was disconnected | Reel saved your place at \(time) and will continue when the drive is connected again. | Close File, Try Again |

  The detail line is the technical reason ("Matroska header found, then the file ends after 4 KB (FFmpeg: End of file).") and is also logged. During auto-advance a next episode that fails is skipped with an OSD, as in M2; the card is for files the user opened.
- **Truncated tail** on the seek bar: the part after `dataEnd` keeps the track but at primary 7% instead of 18%, with a 2 x 12 pt tick at primary 55% at `dataEnd`. The hover pill over the tail shows the time plus "No data after 38:02" at secondary weight, without a thumbnail. Remaining time counts to `dataEnd`.
- **Damaged data OSD**: the standard OSD with the warning glyph at the OSD symbol opacity: "Skipped damaged video at 12:04" or "Skipped damaged audio at 12:04".
- Audio that cannot be decoded at all (decoder open fails): video plays, the OSD says "Audio can't be played: TrueHD 7.1", the audio panel lists the track as disabled with the reason (as subtitles do, 8.7).

## 10. Key bindings

IINA's defaults, because the user never changed them. M1 binds the items without a tag; M2 items are marked. The M2 rows were checked against IINA's own `iina-default-input.conf` (read from the installed app bundle, read-only, on 2026-10-24); the M1 draft of this table had the delay keys as lowercase z / x / c, which IINA does not use.

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
| Shift+Right / Shift+Left (M2) | Next / previous subtitle line (exact seek to its start) |
| Cmd+Right / Cmd+Left, media next / previous, mouse forward / back (M2) | Next / previous episode in the folder |
| Cmd+] / Cmd+[ (M2) | Speed x2 / x0.5 |
| Alt+Cmd+] / Alt+Cmd+[ (M2) | Speed x1.1 / divided by 1.1 |
| Cmd+\ (M2) | Speed 1 |
| Shift+X / Shift+Z (M2) | Subtitle delay +0.5 / -0.5 s |
| Alt+Shift+X / Alt+Shift+Z (M2) | Subtitle delay +0.1 / -0.1 s |
| Shift+C (M2) | Subtitle delay 0 |
| Shift+9 "(" / Shift+0 ")" (M2) | Audio delay +0.5 / -0.5 s; with Alt +0.1 / -0.1 s |
| Shift+- "_" (M2) | Audio delay 0 |
| v (M2) | Show / hide subtitles (M3: the OSD names the key; resets to shown for the next file) |
| r / Shift+R, t (M2) | Move subtitles up / down by 1% |
| Shift+G / Shift+F (M2) | Subtitle size +10% / -10% (45 to 50, 45 to 40) |
| Ctrl+Cmd+S / Ctrl+Cmd+A / Ctrl+Cmd+V (M2) | Cycle subtitle / audio / video track |
| Ctrl+Cmd+P (M2) | Mini player (Reel's choice; IINA's `toggle-pip` command maps to it) |
| Cmd+S (M2) | Screenshot to ~/Pictures/Reel |
| Cmd+L (M2) | A-B loop: set A, set B, clear |
| Cmd+I (M3) | Video Info (IINA: Inspector) |
| Shift+Cmd+O (M3) | Add Subtitle File (Reel's choice) |
| Shift+Cmd+L (M2) | File loop on / off |
| media fast-forward / rewind (M2) | Seek +15 / -15 s |

Bindings live in one table (`InputMap` in ReelCore) loaded from a bundled `input.conf` in IINA's syntax, so a user file can override it later. Key repeat on arrows issues exact seeks; the planner usually continues forward without a flush, and repeats faster than the engine can serve are coalesced like scrubs.

## 11. Settings, resume and data

### 11.1 Settings (M1)

A small Settings window (`Cmd+,`), SwiftUI form, four items:
- Resume playback where I left off (on).
- Show remaining time (on).
- Show a keyframe preview while seeking (on).
- Hardware decoding (on; off forces software, for diagnosis).

M3 adds two rows (mockup `png/27`), grouped under Playback, Video and Audio headings:
- High dynamic range: Full, Limited or Off (default Full; 7.7).
- Output device: System Default or a listed device (7.11; the same list is in Audio, Output Device).

Volume, remaining-time toggle, window frame and controller position are remembered state, not settings. First-run volume is 47, the user's IINA level **(my call)**.

### 11.2 Resume

- Key: a content key, SHA-256 of (file size, first 64 KiB, last 64 KiB), computed at open (about 1 ms on SSD) **(my call)**. It survives renames, moves and different mount points of an external SSD. The last known path is stored for display and debugging only.
- Stored per entry: position, duration, audio stream index, (M2) subtitle choice (track identity: embedded index plus language, title and codec, or the external file name), subtitle delay, audio delay, subtitle size and position when changed for this file, A-B loop points, updated-at. Schema version 2; version 1 entries load with the new fields empty.
- Saved every 5 s while playing, on pause, when a seek settles, on close, on quit and on `applicationWillTerminate`. Writes are debounced to at most one per second, written to a temp file and renamed (atomic).
- Not saved when the position is under 5 s. At less than 30 s from the end, the entry is deleted (finished).
- On open, if an entry exists and the setting is on, the first seek is `.exact(position)` and the OSD shows "Resumed at mm:ss" with Start Over.
- **IINA carry-over (my call).** If Reel has no entry, it reads IINA's mpv watch_later file for the same path, read-only: `~/Library/Application Support/com.colliderli.iina/watch_later/<MD5 of the absolute path, uppercase hex>`, and takes the `start=` value. The first save then writes Reel's own entry. Override the folder with `REEL_IINA_WATCH_LATER` (empty disables it; tests always set it).
- Reel never writes to the system recent-documents list and has no Open Recent menu (the user has `recordRecentFiles` off).

### 11.3 Files

`REEL_HOME` (default `~/Library/Application Support/Reel`), like Haul's `HAUL_HOME`. Tests and screenshots always set a fresh temp dir.

| Path | Contents |
|---|---|
| `REEL_HOME/settings.json` | the four settings, (M3) the High dynamic range value |
| `REEL_HOME/state.json` | volume, remaining-time toggle, window frame, controller fractions, (M3) output device UID and name |
| `REEL_HOME/resume.json` | resume entries keyed by content key, versioned schema |
| `REEL_HOME/logs/reel.log` | local log, rotated at 5 MB, never sent anywhere |
| `REEL_HOME/Caches/thumbnails/<content key>.thumbs` | (M2) thumbnail pack: header, index of (pts, offset, length), JPEG blobs; 500 MB cap, oldest evicted |
| `REEL_HOME/Caches/fonts/PingFang-Medium-<key>.ttc` | (M2) PingFang rebuilt for libass (8.4), keyed by the OS build and the font file; written only by the app or with `REEL_HOME` set |

JSON files instead of `UserDefaults` **(my call)**: one env var isolates everything for tests, and the files are easy to inspect.

Environment variables: `REEL_HOME`, `REEL_FIXTURES` (fixture dir for tests and benches), `REEL_IINA_WATCH_LATER`, `REEL_FORCE_DECODER=hw|sw`, `REEL_LOG=debug`, `REEL_ALLOW_AUDIO=1` (lets a test attach an audio renderer; otherwise none is attached), (M2) `REEL_SCREENSHOTS` (screenshot folder; tests always point it at a temp dir), `REEL_NO_THUMBNAILS=1` (benches that must measure seeks alone).

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
                                   (M2) subs, thumbs, episodes
(M2) ReelCore adds Tracks, ExternalSubtitles, SubtitleCharset, EpisodeList, PlaybackSpeed, LoopState,
     SubtitleStyle, ThumbnailPack; ReelEngine adds SubtitleDecoder, SubtitleRenderer, SubtitleCompositor,
     BitmapSubtitles, SubtitleTrackStore, SubtitlePrefetcher, ExternalSubtitleLoader, ThumbnailGenerator,
     ThumbnailCache, Screenshot; ReelUI adds TrackPanels, SpeedPanel, ThumbnailPill,
     NextEpisodeCard, SubtitleOverlay, AutoAdvance, MiniPlayerView, MiniPlayerGeometry, SnapSpring; Reel adds NowPlaying,
     PictureInPicture, EpisodeNavigator, ScreenshotSaver. scripts/make-pgs.swift writes the PGS fixture.
docs/mockup/                       (M2) static mockup of the M2 surfaces, render.sh, png/
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
| `subs_tracks.mkv` (M2) | 12 s H.264 720p; audio eng E-AC-3 5.1 and jpn AAC 5.1; subtitles zho ASS 简英双语 (default, with a `\pos` sign), zho ASS 繁英雙語, eng SRT, eng SRT SDH; sidecar `subs_tracks.zh-Hans.srt` |
| `subs_utf8.srt`, `subs_gbk.srt`, `subs_big5.cht.srt` (M2) | the same Chinese and English lines in UTF-8, GB18030 and Big5 |
| `subs_ass_signs.ass` (M2) | a positioned sign and a bottom line, for the lift rule |
| `subs_pgs.mkv` (M2) | 8 s 1080p plus a PGS track from `scripts/make-pgs.swift` with two known rectangles (`logs/pgs_rects.json`) |
| `episodes/` (M2) | `Northern.Line.S01E01.mkv`, `E02`, `E03`, `E10` (3 s each), an AppleDouble `._` file and `notes.txt` |

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

**M3 additions.** Fixtures `hdr/` (lossless PQ and HLG patch ramps in HEVC, AV1 and VP9, an SDR control, Dolby Vision 8.1, 8.4 and 5 records), `odd/` (unusual but valid files and three non-media files) and `corpus/` (seeded corruptions of 8 small base files, `scripts/make-corpus.py`). New tools `reelctl hdr`, `energy-bench`, `soak`, `devices` (section 16). `check.sh` gains two gates: `av-sync` (both sync fixtures, 20 ms) and `soak-smoke` (12 corpus files). `shot-stats --patch x y w h` reports the mean sRGB value of a region so the HDR shots can be checked numerically. AddressSanitizer runs only in acceptance (`swift build -c debug --sanitize=address` into its own scratch path), on a 24-file corpus subset. Energy and HDR on-screen behaviour have hands-on checklists (7.7, 7.9) for the user; no test shows a window to check them.

## 15. Visual design

### 15.1 Base (M1)

- The video area is always black in both appearances. The chrome follows the system appearance through standard materials and semantic colours (`.primary`, `.secondary`, accent for the played track only). Nothing is forced dark.
- Title bar: no material band. A black gradient scrim (50% at the top, easing to clear over 68 pt) sits behind the white title so the picture runs to the top edge and the title stays legible on bright frames.
- Typography: SF Pro throughout. Times 12 pt medium monospaced digits; hover pill 12 pt semibold; OSD 20 pt semibold rounded; title 13 pt semibold, centred in the title bar area, white at 88% with a faint shadow, fading with the chrome; empty state 15 pt semibold.
- Spacing: controller padding 14 x 12, 22 pt between transport buttons, 12 pt between the time labels and the seek bar, 16 pt minimum margin from window edges.
- Motion: chrome fade 0.16 s in (15.2), 0.35 s out; track grow spring 0.18 s; hover backgrounds 0.12 s; button press 0.1 s; OSD 0.12 s in, 0.25 s out; controller drag follows directly with no animation; window resize for a new video animates 0.2 s keeping its centre. Reduce Motion: opacity only, 0.1 s.
- App icon: a simple generated icon (`scripts/make-icon.swift`) until a drawn one exists: a rounded square with a dark gradient and a white play glyph, nothing borrowed from IINA.
- Check the controller over pure white and pure black frames (the fixtures include both in the sync flashes).

### 15.2 M2 surfaces

The M2 mockup is `docs/mockup/index.html` (open it in a browser for the gallery with notes; `?frame=<id>&theme=light|dark` shows one frame). `docs/mockup/render.sh` renders every frame with headless Chrome into `docs/mockup/png/` (01 to 18, light and dark where the surface has both; window frames 1280 x 720 pt at 2x, fullscreen 2560 x 1440 pt at 2x). The picture is a generated scene, never real media. Icons in the mockup are drawn stand-ins for the SF Symbols named here. The mockup was critiqued with impeccable (a design review and a detector plus pixel-measurement pass, run separately) and fixed once; the values below are the fixed ones.

**Tokens.** M1's tokens (15.1, 9.3) carry over unchanged. New or newly pinned:

| Token | Light | Dark | Used for |
|---|---|---|---|
| Material | `.regularMaterial` | `.regularMaterial` | controller, panels, pill, OSD, next card |
| Hairline | black 8%, 0.5 pt inside | white 12%, 0.5 pt inside | every material surface |
| Primary text | primary 85 to 90% | primary 85 to 90% | labels, times, titles |
| Secondary text | primary 68% | primary 55% | second lines, counts, "in 3 s" |
| Tag text | primary 62%, 0.5 pt ring at 24% | primary 50%, ring at 24% | format tags (ASS, E-AC-3 5.1) |
| Checkmark | primary 85% | primary 85% | selected track (as `NSMenu` does) |
| Accent | system accent | system accent | played track, changed speed, lit buttons, Play Now, selected speed preset |
| Accent tint | accent 16% | accent 22% | speed capsule when not 1x, A-B range |
| Hover | primary 10% | primary 10% | button circles, panel rows (radius 10) |
| Separator | primary 10%, 1 pt, inset 10 pt | same | panel and menu groups |
| Shadow, large | contact radius 1.5 y 1 at 22% + ambient radius 28 y 10 at 28% (M1 controller) | same | controller, panels, next card |
| Shadow, small | contact radius 1 y 1 at 16% + ambient radius 9 y 4 at 22% | same | OSD, thumbnail pill |

Secondary text is 68% in light because the impeccable measurement found M1's 55% at 3.8:1 on the light material over a dusk frame; 68% reaches about 4.6:1. Checkmarks are primary, not accent, because accent on the light material measured 1.9:1.

**Radii** (concentric where nested: inner = outer minus padding): controller 24; next card 20 with a 12 pt pad, so its thumbnail is 8; panels 16 with a 6 pt pad, so rows are 10; OSD 14; pill 12 with a 4 pt pad, so the thumbnail is 8; steppers 8; speed segments 7 inside a 9 track; format tags 5; buttons and capsules fully round.

**Type** (SF Pro; rounded where noted): panel header 13 semibold, count 11 medium; row label 13 medium; row detail 11.5 regular (Chinese titles in PingFang SC at the same size); tag 10.5 semibold with +3% tracking; speed label 13 semibold rounded with monospaced digits; speed presets 12 semibold rounded; stepper values 13 medium monospaced digits; next card title 13 semibold, episode name 13 medium, countdown 12 medium monospaced digits; capsule buttons 12 semibold; fullscreen end time 12 medium. OSD stays 20 semibold rounded.

**Sizes per surface.**

| Surface | Geometry |
|---|---|
| Controller | height 80, radius 24, padding 14 x 12, width `clamp(0.45 x window, 440, 600)`, at most 70% of the window; bottom row clusters as in 9.3; fullscreen bottom 56 |
| Speed label button | height 28, min width 36, padding 0 x 6, capsule; 6 pt before the symbol buttons |
| Track panel | width 320, padding 6, header 8/10/6, rows min 30 (42 with a second line), check column 22, steppers 60 x 26 (two 30 pt cells), max height 60% of the window then scroll; bottom 10 pt above the controller; centred on its button, 16 pt inside the window |
| Speed panel | width 264; preset track 26 tall with 3 pt inset; Fine stepper row |
| Thumbnail pill | 4 pt padding; image 192 x 108 (aspect, height 80 to 144); time row 22; bottom 8 pt above the controller; centred on the pointer, 16 pt inside the window |
| Loop marks | 3 x 14 capsules on the track, range tint full track height |
| OSD | unchanged (padding 16 x 10, radius 14, 20 pt from the corner, +28 under visible chrome) |
| Next card | 360 wide, padding 12, gap 12, thumbnail 128 x 72, ring 34 (stroke 2.5, track white 30%, progress white), buttons 26 tall; 12 pt above the controller, right edge on the controller's right edge |
| Subtitles | 8.4 and 8.5: size 45 on the 720 reference, outline 2.5, shadow 1.4 down, margin 40, lift to 12 pt above the controller |

**Motion.** From a `find-animation-opportunities` pass over the M2 surfaces, gated on frequency, purpose, budget and function. Curves: ease-out is `cubic-bezier(0.23, 1, 0.32, 1)` (SwiftUI `.timingCurve(0.23, 1, 0.32, 1, duration:)`), ease-in is `(0.4, 0, 1, 1)`, ease-in-out is `(0.65, 0, 0.35, 1)`. With Reduce Motion every movement below becomes an opacity change of 0.1 s.

| Surface | What moves | Duration and curve | Purpose |
|---|---|---|---|
| Chrome reveal (traffic lights, title, controller) | opacity 0 to 1 | 0.16 s on the shared ease-out token (at least 90% opaque by 60 ms); the traffic lights use the same control points through `CAMediaTimingFunction` | feedback: a key press shows the time at once; 100+ times a day, so it gets the fastest curve and no extra movement |
| Chrome hide | opacity 1 to 0 | 0.35 s ease-in (`0.4, 0, 1, 1`), traffic lights in the same transaction | the chrome leaves without a cut |
| OSD shift under the title | the OSD's 28 pt move when the chrome shows or hides | the chrome's timing, in and out | the OSD and the chrome move as one |
| Track and speed panels, open | opacity 0 to 1 and scale 0.96 to 1 from the point over the button (x is `(button centre - panel left) / panel width`, clamped to 0 to 1, y is the bottom edge), recomputed when the panel is clamped inside the window | 0.16 s ease-out | spatial: it grows from the button that opened it |
| Panels, close | opacity only | 0.12 s ease-in | quick exit, nothing to follow |
| Switching straight from one panel to another | nothing: the panel swaps in place | instant | the panel does not slide or resize between buttons; the rows change with it |
| Press feedback | 0.94 scale on pointer-down for capsule and icon buttons (Start Over, Show, the range tag, failure card buttons); a fill of primary 16% for the stepper cells, set at once and fading back in 0.1 s | 0.1 s ease-out | feedback; steppers are pressed in bursts and a scale would pull half a cell off its divider |
| Empty state, file dragged over | tile fill white 10% to 16%, ring white 14% to accent 60%, scale 1 to 1.04 about the centre; only while no media is open | 0.16 s ease-out in, 0.12 s ease-in out; Reduce Motion: fill and ring only, 0.1 s | feedback: the file will be accepted |
| Thumbnail image arriving under a resting pointer | opacity | 0.12 s ease-out | no pop-in |
| Speed button when the rate leaves or returns to 1 | colour and capsule fill | 0.15 s ease-in-out | state change is noticed |
| A-B marks set or cleared | opacity | 0.12 s ease-out | state |
| Subtitle lift up | bottom lines snap up | none; it happens as the chrome starts to appear | the lift fires on every chrome reveal (100+ times a day), the lines are text being read, and animating them would mean a libass render per frame |
| Subtitle lift down | bottom lines snap back | none; it happens after the 0.35 s chrome fade-out ends | text never moves under a fading controller |
| Next card, enter | opacity and translate y 12 to 0 | 0.32 s ease-out | a rare, end-of-episode moment |
| Next card, exit | same path back | 0.2 s ease-in | symmetric exit |
| Countdown ring | stroke end 0 to 1 | 5 s linear, paused while hovered | state (time left) |
| Mini player | enter and leave, corner snap, chrome | mini player design section 8 | spatial consistency |

Reduce Motion, per surface: the chrome fade, the OSD (no scale), the panels and Video Info (no scale) and the empty-state tile become a 0.1 s linear opacity change; the seek track uses the same 0.1 s instead of its spring; the volume slider width and the window frame change (a new video, Cmd+0 to 3) jump with no animation; the stepper fill is a colour change and stays.

Rejected, on purpose: OSD text on repeated key presses (changes in place, M1 rule; keyboard actions run hundreds of times); keyboard track cycling (OSD only, no panel); individual subtitle lines (never animated by Reel; ASS `\fad` stays authored); the thumbnail pill following the pointer (1:1, no smoothing); switching episodes (the old frame stays until the new first frame, like a seek; no cross-fade); controller relayout on window resize (resizing is direct manipulation); the speed preset selection (instant).

**Accessibility.** Hit targets at least 28 pt (play 32, steppers 30 x 26, panel rows 30). Every control has an accessibility label and value ("Subtitles, Chinese (Simplified)", "Speed, 1.5 times"). Measured in the mockup: controller times 8.2:1 (light) and 10.9:1 (dark); panel labels 9.0:1 and 11.9:1. With Reduce Transparency the materials become `windowBackgroundColor` at 96% with the same hairline. Subtitle white on its black outline is about 21:1 whatever the frame.

### 15.3 M3 surfaces

Mockup frames 19 to 27 in `docs/mockup/index.html`, rendered by `docs/mockup/render.sh` into `docs/mockup/png/19-*` to `27-*` (light and dark, 1280 x 720 pt at 2x). They extend the M2 tokens; nothing in 15.2 changes. The Dolby Vision colour cast in `png/22` is an illustration (a hue rotation of the generated scene), not a measured result. Checked with impeccable (craft floor and the mechanical detector, no findings) and one fix round: the info rows lost their default list margins, the tooltip moved clear of the pointer, the truncated tail became fainter than the unplayed track instead of darker, and the settings menu was no longer clipped.

New tokens:

| Token | Light | Dark | Used for |
|---|---|---|---|
| Range tag | white 88% text on white 12%, ring white 28% (fixed) | same | title bar tag |
| Range tag detail | white 62%, weight 500 | same | "SDR" |
| Warning glyph | `#b25000` on material, system yellow on the scrim | system yellow | DV note, tag, damaged OSD in dark |
| Missing data | primary 7% track, tick primary 55% | same | truncated tail |
| Failure text | white 86 / 72 / 56 / 50% (title, explanation, file, detail) | same (fixed, on black) | failure card |
| Dimmed frame | brightness 38%, saturation 70% | same | drive gone |

Type: tag 10.5 semibold +3%; Video Info header 13 semibold, rows 12 regular with monospaced digits, second lines 11.5; note title 15 semibold, body 12 regular; failure title 15 semibold, explanation 13 regular, file 12 medium, detail 11 regular. Radii: tag 5, Video Info 16 (rows unboxed), note 14 (the OSD), failure tile 16, capsules round.

**Motion** (from the apple-design pass: respond at once, enter and leave along the same path, no bounce on anything that did not come from a gesture; Reduce Motion turns every entry below into a 0.1 s opacity change):

| Surface | What moves | Duration and curve | Purpose |
|---|---|---|---|
| Range tag | nothing of its own; fades with the title and chrome | chrome timing (9.2) | stays part of the title |
| Tag detail "SDR" appearing or leaving | opacity cross-fade | 0.15 s ease-in-out | the change is noticed without a jump |
| Video Info, open | opacity 0 to 1, scale 0.96 to 1 anchored on its top edge at the point under the tag (x is `(tag centre - panel left) / panel width`, clamped to 0 to 1; the top-left corner when there is no tag) | 0.16 s ease-out | it grows from the tag that opened it, like the track panels |
| Video Info, close | opacity | 0.12 s ease-in | quick exit |
| Video Info values | none (text changes in place) | | numbers update twice a second; motion would flicker |
| DV note | the OSD entry (opacity, scale 0.96 to 1) | 0.12 s in, 0.25 s out | same component as every OSD |
| Failure card on open failure | opacity | 0.2 s ease-out | calm; a failure gets no shake or bounce |
| Drive gone | frame dims to 38% brightness, then the card fades in | 0.3 s ease-out, card 0.2 s after 0.1 s | avoids an abrupt brightness drop; the reverse on reconnect, 0.2 s |
| Truncated tail, damaged tick | none | | state, drawn statically |
| Damaged OSD | standard OSD | 0.12 s in, 0.25 s out | |

Rejected: animating the headroom meter, pulsing the warning glyph, sliding the failure card in, and any animation when the window changes display.

**Accessibility.** The tag has the label "Dynamic range, HDR10" (plus ", tone-mapped to standard range" when it shows "SDR") and the button trait. Video Info rows read as "key, value". The note is announced through `NSAccessibility.post(.announcementRequested)` once. Failure cards put focus on the primary button and Return activates it. Targets, measured by M3-7 on the background shots: every text at least 4.5:1 against its measured background (failure detail text, 11 pt at white 50% on black, is the closest case at about 5.3:1 by calculation), Video Info keys at the 15.2 secondary values.

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

Scope (unchanged from the M1 plan, detailed in sections 8, 9.3 to 9.12, 10 and 15.2):

- Subtitles: libass, embedded text tracks, PGS and DVD bitmaps, external file discovery, GB18030 and Big5 fallback, zho then eng preference, size 45 default, delay, size and position keys, lift above the controller, background prefetch of text events.
- Audio and subtitle track panels in the controller and menus in the menu bar; video track cycling.
- Thumbnail preview on the seek bar: keyframe-only decode in the background (VideoToolbox scaled to 384 x 216 BGRA, JPEG pack per content key under `REEL_HOME/Caches/thumbnails`), manual keyframe packet feed for VP9.
- Next and previous episode in the folder (natural sort), Cmd+Right/Left, controller buttons, media keys, mouse side buttons; auto-advance at the end with a 5 s card. Folder access usage strings.
- Playback speed 0.25 to 4 with pitch preservation, presets and fine steps.
- VP9 hybrid decoder (software for long exact seeks, hardware for playback, hand-off at the next keyframe).
- Picture in Picture with the sample buffer layer content source, subtitles composited while active, a main-window placeholder (replaced by the mini player on 2026-10-26, section 9.9).
- Fullscreen polish: controller 56 pt from the bottom, menu bar and cursor hide with the chrome, end time at the top right.
- Now Playing and media keys (`MPRemoteCommandCenter`, `MPNowPlayingInfoCenter`).
- Default-app document types: `CFBundleDocumentTypes` (Viewer, rank Default) and `UTImportedTypeDeclarations`; the user sets Reel as default in Finder.
- Cmd+S screenshot, A-B loop and file loop. Music mode only if asked.

Build order. Seven tasks; the brief for the build loop lists the files each one owns, and tasks that run in parallel own disjoint files.

1. **M2-1 Core contracts and fixtures.** `PlayerEngine` commands and `EngineEvent`s for tracks, delays, speed, loops, thumbnails and subtitle avoidance (each with a default no-op so every engine keeps compiling); pure logic in ReelCore (`Tracks`, `ExternalSubtitles`, `SubtitleCharset`, `EpisodeList`, `PlaybackSpeed`, `LoopState`, `SubtitleStyle`, `ThumbnailPack`), M2 key bindings, resume schema v2; `reelctl episodes` and stubs for `subs` and `thumbs`; fixtures for subtitles (bilingual ASS, SRT, SDH, sidecar, GBK, Big5, PGS from a generated `.sup`) and an episode folder.
2. **M2-2 Subtitle engine** and **M2-3 Thumbnail engine**, in parallel. Standalone engine components plus `reelctl subs` and `reelctl thumbs`.
3. **M2-4 Engine integration** and **M2-5 UI surfaces**, in parallel. M2-4 wires subtitles, thumbnails, track switching, delays, speed, loops, VP9 hybrid, screenshots and PiP compositing into `PlaybackEngine`. M2-5 builds every surface of 15.2 in ReelUI against the protocol and adds the shot scenarios.
4. **M2-6 App shell.** Subtitle layer, PiP, fullscreen, Now Playing, menus, keys, folder scan, screenshot saving, Info.plist document types and usage strings, shot mode inputs.
5. **M2-7 Shots and acceptance.** New shot scenarios, `shot-stats --ink`, the M2 acceptance group, CLAUDE.md commands, measured numbers back into this document.

New `reelctl` commands (headless, no window, no audio):

- `subs <file> [--track ...] [--external path] [--no-external] [--at s] [--size WxH] [--frames N] [--out png] [--dump-text] --json`: selected track and reason, charset, ink pixels, bounding box, missing glyphs, fonts, render time.
- `thumbs <file> [--runs N] [--fresh-cache] [--out-dir dir] --json`: count, setup time, per-thumbnail time (amortised and latency), sizes, blankness, cache size and reload time.
- `episodes <file> --json`: the folder's episode order, index, next and previous.
- `seek-bench --with-thumbs` runs thumbnail generation during the bench; `REEL_NO_THUMBNAILS=1` turns it off.

Acceptance (each checked by a command; the exact commands are in the brief and in `scripts/accept.sh` once M2-7 lands):

1. All gates green, including bundle, codesign and the document types in Info.plist.
2. Subtitles on the generated SRT, ASS, PGS, GBK and Big5 fixtures, including Chinese text, checked by `reelctl subs`: default track choice, ink and position, zero missing glyphs with a PingFang face, nothing between events, charset detection with identical text, PGS rectangles within 2 px, steady render p95 at most 16 ms at 1080p.
3. Thumbnails per fixture: amortised p95 at most 15 ms (HEVC and H.264 1080p), 40 ms (AV1 4K), 60 ms (VP9 4K); setup at most 150 ms; cache reload at most 50 ms; and the HEVC seek thresholds of 7.6 still hold with thumbnails generating.
4. Episode order (natural sort, junk files excluded) and auto-advance (countdown, cancel, hover pause, loops, carry-over) tested.
5. Background shots of every new surface in light and dark, non-blank, appearance-dependent, subtitles detected by outlined-ink counts, no window, frontmost app unchanged.
6. VP9 exact worst-case p95 at most 800 ms with correct frames and at least one decoder hand-off; M1's seek and sync criteria still pass.

The thumbnail budgets come from the spike: the first VideoToolbox frame arrives 5 to 23 ms after a keyframe is submitted and one session decodes about 200 1080p keyframes per second; 4K keyframes cost 2 to 4 times more. The VP9 budget comes from software decode at 576 fps 4K (a 300-frame GOP in about 520 ms) plus demux and hand-off.

### M2 status

First measured on 2026-10-24 by `scripts/accept.sh offline` (results in `build/accept/<timestamp>/results.tsv`), headless, on the fixtures; the rows for AC-M2-2, 3, 5 and 6 were measured again with the same `reelctl` commands and `scripts/shots.sh` after the fixes below. Thresholds are unchanged.

| Criterion | Result | Measured |
|---|---|---|
| AC-M2-1 gates, document types | PASS | `check.sh` exits 0; mkv, webm, mp4, mov, avi, flv (plus ts, ogv and audio types) all `LSHandlerRank` Default; `NSDocumentsFolderUsageDescription` present. `check.sh` now fails if either is missing. |
| AC-M2-2 subtitles | PASS | Sidecar chosen, embedded zho ASS 简英双语 with `--no-external`; ink 30003 at 2.0 s, 0 at 0.5 s; 0 missing glyphs; `fonts` is `PingFangSC-Medium` with no substitution (8.4: PingFang rebuilt from CoreText outlines); bbox centre x 947.5 (limit 941 to 979), bottom 1021 (918 to 1048); GB18030 and BIG5 text identical to UTF-8; PGS bbox equals the first rectangle exactly, 0 ink at 3.5 s; render p95 0.012 ms over 100 frames; the three suites pass. Traditional and Hong Kong sidecars draw with `PingFangTC-Medium` and `PingFangHK-Medium`, Ext-B characters (𠮷 𡃁 𨋢) included, 0 missing glyphs. |
| AC-M2-3 thumbnails | PASS | Amortised p95 (ms, budget): HEVC 2.6 (15), H.264 3.1 (15), AV1 3.1 (40), VP9 11.8 (60). Max latency: 7.8, 10.5, 7.4, 65.9 (limits 45, 45, 120, 180). Setup: 9.5, 78.6, 7.4, 105.6 (limit 150). Counts equal the keyframe totals (6, 6, 8, 8), every image 384 px wide, min luma stddev about 55, cache reload under 0.3 ms. Setup now ends with a synchronous decode of the first keyframe (9.4), so the session's first-frame cost (18 ms for the 1.27 MB H.264 keyframe) is counted in setup and that frame becomes its thumbnail. Without the process warm-up (`--cold`) H.264 is 3.1 ms amortised with setup 134 ms; VP9 setup is then 152.5 ms, over 150 (not gated: the criterion runs without `--cold`). HEVC seek with thumbnails generating: keyframe p95 7.6 ms, exact worst p95 47.2 ms, 45 of 45 exact seeks on the expected frame. |
| AC-M2-4 episodes | PASS | Order S01E01, E02, E03, E10; next E03, previous E01; the seven named tests pass. The path is now compared as the file system spells it, so `.../projects/reel/...` finds the folder too. |
| AC-M2-5 shots | PASS | 32 PNGs at 2560x1440; outlined ink 14304 (subtitles, bottom quarter, both themes); 32 launches with `lsappinfo front` equal before and after, none registered as an application (`lsappinfo find pid=`), and 4 libass subtitle renders logged. Shot mode no longer draws sample lines when libass output is missing: the shot fails. |
| AC-M2-6 VP9 and M1 | PASS | Exact worst p95 547 ms (limit 800), keyframe p95 25 ms (limit 100), 45 of 45 landed, PSNR 99 dB, 25 hand-offs; M1 seek thresholds (HEVC 47.7, H.264 196, AV1 407 ms exact worst p95) and both A/V sync fixtures pass. Play after a software landing no longer enqueues the next frames late: paused, the receiver holds only one 4K frame past the shown one, so frames due within 100 ms of the clock are enqueued without waiting for it. |

Fixed after the first acceptance run: `EpisodeList.scan` compared URLs by spelling; `reelctl thumbs` printed `warmup_ms` as about 1.8e13 (the report's finish time was set by a `defer` after the return value was copied). Later: screenshots go to `REEL_HOME/Screenshots` when `REEL_HOME` is set and `REEL_SCREENSHOTS` is not; tests that raced (restarted thumbnails, the VP9 hand-off count, the audio flush restart, auto-advance) wait on conditions instead of fixed sleeps or 2 s deadlines.

### M3: trusted HDR, low energy, no surprises on bad files

Why: a user-research pass (2026-10-25; Reddit could not be read, so it rests on the IINA tracker, the Firecore and VideoLAN forums, MacRumors and Hacker News) ranked the P1 gaps for Reel as: HDR10 and HLG that are correct on the built-in XDR display and external displays without dimming the screen; Dolby Vision that never shows wrong colour silently; an energy budget against QuickTime; and reliability on odd and damaged files with A/V sync kept under a gate. Seeking, the headline of M1 and M2, stays as it is and keeps its gates.

Scope (detailed in 7.7 to 7.11, 9.13, 9.14, 11.1 and 15.3):

- HDR10 and HLG: complete colour attachments on both decode paths, `DynamicRangePlan` and the display layer's `preferredDynamicRange`, chrome and subtitles at SDR white, PiP subtitles at reference white, `DisplayRangeMonitor`, `HDRToneMapper` for screenshots, thumbnails, artwork and shots, the High dynamic range setting.
- Dolby Vision: detection, the compatibility policy, the profile 5 note, the `--dovi-session` probe.
- Energy: `EnergyPolicy`, paused and occluded behaviour, timer leeway, Low Power Mode thumbnails, `reelctl energy-bench`, the hands-on QuickTime comparison.
- Robustness: `MediaProblem` and the failure card, damaged-data skipping, `dataEnd` and the truncated tail, drive disconnect and automatic reopen, odd-file fixes, the corpus, `reelctl soak`, an AddressSanitizer pass.
- Small items: v OSD and reset, Shift+Cmd+O, output device choice, Video Info.

Not in M3: Dolby Vision RPU reshaping, HDR10+ dynamic metadata beyond what VideoToolbox propagates, audio passthrough or spatial audio settings, AirPlay, user key remapping.

Build order. Seven tasks; tasks that run in parallel own disjoint files (the brief lists them).

1. **M3-1 Core contracts and fixtures.** ReelCore: `DynamicRange` (content classification), `DolbyVisionConfig` in `MediaInfo`, `DolbyVisionPolicy`, `DynamicRangePlan`, `HDRSetting` in settings, `EnergyPolicy`, `MediaProblem` with its copy, `OutputDeviceChoice`, `PlayerEngine` additions with default no-ops (`setOccluded`, `setOutputDevice`, energy counters, events `.dynamicRange`, `.dataEnd`, `.damaged`, `.problem`), the Shift+Cmd+O and Cmd+I bindings; the Dolby Vision hook in the demuxer's stream info; fixtures `hdr/` (`make-ramp.py`, `make-dovi.py`) and `odd/`; `reelctl` stubs for `hdr`, `energy-bench`, `soak`, `devices`.
2. **M3-2 HDR and Dolby Vision engine**, **M3-3 Energy engine** and **M3-5 UI surfaces**, in parallel after M3-1.
3. **M3-4 Robustness engine** after M3-3 (both change `PlaybackEngine`).
4. **M3-6 App shell** after M3-2, M3-4 and M3-5: layers and plans, occlusion and screen observers, Video Info and output device menus, Settings rows, drive mount handling, shot mode inputs.
5. **M3-7 Gates, shots and acceptance**: `check.sh` gains `av-sync` and `soak-smoke`, `accept.sh` gains the M3 group, `shots.sh` the 8 new scenarios and `shot-stats --patch`, CLAUDE.md commands, measured numbers into this section.

New `reelctl` commands (headless, no window, no audio):

- `hdr <file> [--decoder hw|sw] [--display sdr|xdr|external|headroom=X] [--setting full|limited|off] [--screenshot png] --json` (7.7).
- `probe <file> --json` gains `dolbyVision`; `probe <file> --dovi-session` (7.8, hands-on only).
- `energy-bench <file> --mode play|paused|occluded [--seconds N] [--warmup N] --json` (7.9).
- `soak <file|dir> [--seed S] [--ops N] [--seconds N] --json` and the internal `soak-one` (7.10).
- `devices --json` (7.11).

Acceptance (each checked by a command; exact commands in the brief and in `scripts/accept.sh m3` once M3-7 lands):

1. All gates green, now including the av-sync gate (both sync fixtures, at most 20 ms sequentially and after 10 seeks) and the soak smoke gate (12 corpus files, no crash or hang); every M1 and M2 criterion still passes.
2. HDR10 and HLG numbers on the ramps (7.7): patch codes, attachments, plans for SDR, XDR and external displays under each setting, tone-mapped values, PiP subtitle codes, HDR thumbnails, and the layer configuration suite.
3. Dolby Vision (7.8): profile and compatibility detected in mp4 and mkv, 8.1 decodes to the PQ ramp's codes with an HDR10 plan, 8.4 to the HLG plan, profile 5 yields the note and the warning tag, RPU and EL NAL types never skipped as non-reference.
4. Energy (7.9): the budget table holds for play, paused and occluded, with zero decode and zero periodic events while paused, and resync after occlusion within 300 ms.
5. Robustness (7.10): the whole corpus and `odd/` through `reelctl soak` with no signal exit, no operation over 5 s, no descriptor or thread leak, every failure classified with non-empty copy, `dataEnd` within 1 s on the truncated files, playback past the damaged region on the corrupt files with `damagedFrames` above 0, and no AddressSanitizer report on a 24-file subset.
6. Background shots of the 8 M3 scenarios in light and dark (on top of M2's 16), non-blank, appearance-dependent, the HDR scenarios' patches tone-mapped (203-nit patch region mean 190 to 250), frontmost app unchanged, no window.
7. Small items: Shift+Cmd+O and the v OSD and reset tested, `reelctl devices --json` lists at least one output device with UID and name without attaching a renderer, the output device choice resolves and falls back as specified.

### M3 status

Built on 2026-10-25 (tasks M3-1 to M3-7, then two fix rounds). Measured headless on the generated fixtures by `scripts/accept.sh offline` (run `build/accept/20261025-150259` after the second fix round, results in its `results.tsv`) and the `reelctl` commands behind it; thresholds are unchanged. Acceptance items 1 to 7 above are AC-M3-1 to AC-M3-7 in the script; AC-M3-8 (SDR colour against ColorSync and QuickTime), AC-M3-9 (a display without EDR headroom) and AC-M3-10 (motion gate fixes) were added to it in the fix round. Every M1 and M2 criterion passes in the same run (AC01 to AC05, AC-M2-1 to AC-M2-6), and `lsappinfo front` was the same before and after every launch.

| Criterion | Result | Measured |
|---|---|---|
| AC-M3-1 gates | PASS | `check.sh` exits 0 with every gate ok, including `av-sync` (max 0.0 ms sequentially and after 10 seeks on both fixtures) and `soak-smoke` (12 files, 0 crashes, 0 hangs, 0 mismatches); all 11 M1 and M2 criteria pass. Before the second fix round `swift test` failed in about one run in four (see below); after it, 7 full runs in a row passed at the width `check.sh` uses (8), and one at width 4. |
| AC-M3-2 HDR10 and HLG | PASS | Twelve runs (six ramp files, hw and sw): decoded codes exact (error 0); attachments ITU_R_2020, ITU_R_2020 and PQ or HLG; PQ files carry MDCV 1000 nits and CLL 1000 and 400. Tone-mapped neutral patches, identical from `HDRToneMapper` and the screenshot PNG: PQ 0, 2, 15, 63, 186, 229, 250, 255, 255, 255; HLG 0, 16, 61, 137, 229, 253, 255; spread 0. Thumbnail reference white 229. PiP subtitle Y 573 (PQ) and 721 (HLG). SDR control and the nine display and setting plans as specified; the five suites pass. HLG is brighter than QuickTime at reference white (7.7). |
| AC-M3-3 Dolby Vision | PASS | As before: profiles and compatibility ids detected in mp4 and mkv, dv81 decodes to the PQ ramp's codes (hw and sw), dv84 has the HLG base, dv5 gives the note, tag and warning. Those fixtures carry no RPU. The third fix round added `dv81_rpu.mp4`, `dv84_rpu.mp4` and `dv5_rpu.mp4` with an RPU on every frame (7.8): AVFoundation plays them, its 8.1 image equals the PQ ramp's and Reel's, Reel gives the same codes, tags and notes as for the record-only files, and VideoToolbox's Dolby Vision session passes profile 5 RPUs on without reshaping (`DolbyVisionRPUTests`). Real graded content (a non-identity RPU) stays hands-on check 7. |
| AC-M3-4 energy | PASS | hevc10 play: CPU 2.89% (budget 4), 115 wakeups per s (150), 481 frames. av1 play: CPU 4.88% (10), 114 wakeups per s (300), 1201 frames. Paused, both: CPU 0.00%, 0.9 to 1.0 wakeups per s, 0 frames, packets, subtitle renders and time events. hevc10 occluded: CPU 1.02% (2), 20 wakeups per s (60), 0 frames after the first second, resync 26 ms (300). The M2 baseline is in 7.9; no budget is beaten by more than 3 times there, so none was tightened. The Spotlight indexer was using about two cores during these runs. `EnergyTests` passes. |
| AC-M3-5 robustness | PASS (third fix round, reelctl runs; not yet through `accept.sh`) | Corpus (release `reelctl soak`, seed 1, 30 ops): 112 files, 0 crashes, 0 hangs, 0 leaks, 0 mismatches, 0 damage misses, 88 played and 24 classified with copy, longest operation 714 ms, the 11 truncated files within 1.0 s of their dataEnd. `odd/`: 19 files, 0 crashes, hangs, leaks or mismatches; zero.mkv, text.mp4 and random.mkv notMedia, prores.mov unsupportedCodec, the other 15 played. AddressSanitizer (the 24 files plus `vp9.overwrite50.webm` and `vp9.webm`, seed 2): 0 crashes, no AddressSanitizer line. Every zero-filled and 50% overwrite file plays through with damaged frames above 0, now including `vp9.overwrite50.webm` (5), found by the VP9 tile check (7.10, D69). `flv1.overwrite50.flv` counts 2 (libavcodec's concealment flags). `RobustnessTests`, `OddFileTests`, `VP9TileCheckTests` and `CheckBudgetTests` pass. |
| AC-M3-6 shots | PASS | 16 M3 PNGs (48 in all) at 2560x1440, not blank, light and dark regions apart, the 203-nit patch of hdr-badge 229 in both appearances, front app unchanged, no window. The drive-gone shot no longer registers the process as an application: the failure card uses fixed symbol names instead of asking `NSImage` whether a symbol exists. |
| AC-M3-7 small items | PASS | The named tests for Cmd+I, Shift+Cmd+O, the main menu, the v OSD and its reset, the output device choice and the Settings rows pass; `reelctl devices --json` lists the devices with exactly one default and attaches no renderer. |
| AC-M3-8 SDR colour | PASS | `reelctl color --frame 12`, hw and sw: `bars709_h264.mp4` and `bars709_untagged_h264.mp4` match `AVAssetImageGenerator` on all 24 patches (difference 0), attachments ITU_R_709_2 for primaries, transfer and matrix (the untagged file read as BT.709). `bars601_sd_h264.mp4`, now 704 x 480, is read as SMPTE 170M (SMPTE_C, ITU_R_709_2, ITU_R_601_4) and matches QuickTime within 1 code on all 24 patches: Reel uses VideoToolbox's SD rule (at most 704 x 576), so a 720 x 480 file is BT.709 in both (7.7). Screenshots carry an ICC profile, the image is not in device RGB. `ColorPipelineTests` passes, including a test that the display layer gets the decoder's own YCbCr buffer with the stream's colour and no gamma, filter or compositing filter, and `DynamicRangeLayerTests` checks the app's layer for SDR content. |
| AC-M3-9 no headroom | PASS | `--display-headroom 1.0`: toneMapToSDR for both files; PQ 0, 2, 15, 63, 186, 229, 250, 255 up to 1000 nits, HLG 0, 16, 61, 137, 229, 253, 255; reference white 229; black 0. `--display-headroom 4.0`: edr. The runtime display change test passes. |
| AC-M3-10 motion | PASS | The eight named `MotionTests` pass and 15.2 says the subtitle lift snaps. |

Fixed in the fix round, with a test each: after damage, video resumed at an HEVC CRA but still submitted its RASL pictures, which failed and sent the feeder back to waiting GOP after GOP (one 4 KB overwrite in a 20 s open-GOP file: 349 of 480 frames damaged, now 24); while video was stopped for occlusion the file ended at the audio end (or at 0 with no audio and no duration), now it ends at the last video packet the demuxer read; `setPointerRecent` on `PlaybackEngine` resolved to the protocol's no-op default, so paused thumbnails never waited for the pointer; `setOutputDevice` on `PlaybackEngine` was the protocol's no-op too and now reaches the renderer; an audio decoder that fails to open is reported as `.audioTrackFailed` and the track is listed as disabled; the failure card's detail line now takes FFmpeg's reason when `.problem` arrived without one; the cached format description is reused only when it matches the buffer (a software frame after VideoToolbox ones failed with -12743); Matroska cluster checksums count as damage.

Fixed in the second fix round (run `build/accept/20261025-150259`): `swift test` failed in about one full run in four, each time on a different timing check (the open watchdog test at 3.3 and 4.4 s against 3 s, the A-B loop running 0.4 s past B, an audio flush, the VP9 hand-off count, a thumbnail progress event). A probe of the cooperative pool showed a 5 ms sleep running up to 3 s late in the first 7 s of the run: the synchronous decode cases and about 25 engines' feeders blocked in VideoToolbox held every pool thread. Engine changes: the blocking part of an open and its watchdog run on a thread and a Dispatch timer (7.10); the A-B loop boundary observer fires on its own queue instead of the main queue; a VP9 hand-off whose drain already put out the landing stands when the feeder is parked for pause (it was undone, leaving the report's count above the engine's); and an exact seek right after a paused landing waits for the park in flight, which held the feeder's state, so a forward seek inside the GOP continues the decoder again instead of restarting from the keyframe (`forwardSeekInsideTheGOPContinuesWithoutRestarting` failed on every run with fewer tests in parallel). Test changes, no check loosened: the open timeout is timed on its own executor; the thumbnail test waits for the progress event instead of reading the log at once; the audio flush test reads the clock and the decoded end together; the synchronous decode suites (`VideoDecodeTests`, `HDRDecodeTests`, `HDRToneMapTests`, `PiPCompositeHDRTests`) are serialized; and `check.sh` and `accept.sh` set `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=8` (the test gate takes about 53 s instead of 45 s). SDR colour: the untagged SD rule is VideoToolbox's (7.7) and the SD bars fixture is 704 x 480.

**Hands-on checks for the user** (cannot be automated without a visible window). Record the results here.

HDR (from 7.7):

1. Built-in XDR display, brightness at about 50%: open `build/fixtures/hdr/pq_ramp_hevc.mp4` in Reel and in QuickTime Player side by side. The 1000-nit patch should be visibly brighter than the white menu bar in both; the desktop, menu bar and Reel's controller must not dim in Reel more than in QuickTime.
2. Drag the window to an SDR external display and back: the tag gains and loses "SDR", the 400 and 1000 nit patches stay distinct on the SDR display, nothing flashes.
3. An external HDR display with HDR on in System Settings: same as step 1.
4. Settings, High dynamic range, Limited and then Off: highlights get dimmer, the picture stays correct.
5. Cmd+S on the ramp: the PNG looks like the SDR display in step 2.
6. If a real Dolby Vision profile 5 file is at hand: `reelctl probe --dovi-session <file>` once. On the generated `hdr/dv5_rpu.mp4` the session decodes every frame and attaches the RPU without reshaping, and `AVAssetImageGenerator` does reshape (7.8); a real file confirms whether the display pipeline would do the reshaping for Reel (decides whether M4 needs a reshaping path).
7. A real Dolby Vision 8.1 file and a real profile 5 file (the generated `*_rpu.mp4` fixtures have real RPUs but an identity reshaping, 7.8): open each in Reel and in QuickTime Player side by side. 8.1 should look like QuickTime apart from the RPU's dynamic mapping, which QuickTime applies and Reel does not (Reel plays the HDR10 base); profile 5 shows the note and the warning tag.

Energy (from 7.9): open `build/fixtures/h264_1080p30.mp4` and `build/fixtures/hdr/pq_ramp_hevc.mp4` in QuickTime Player and in Reel in turn, play each for 2 minutes in a window, and read Activity Monitor's Energy tab ("Avg Energy Impact" after 2 minutes) or run Instruments with the Power Profiler template. Target: Reel at most 1.5 times QuickTime on the same file, and Reel at or near 0 while paused.

| Check | Reel | QuickTime |
|---|---|---|
| h264_1080p30.mp4, Avg Energy Impact | | |
| pq_ramp_hevc.mp4, Avg Energy Impact | | |
| Paused | | |

## 17. Risks

- Real files are heavier than the noise fixtures; real-world exact seeks will be slower than the bench. The keyframe preview is the mitigation, and M2 thumbnails add another.
- Requesting `420v`/`x420` from VideoToolbox may cost bandwidth at 4K60 versus the native compressed formats. If 4K60 playback drops frames, try the native formats and verify the layer accepts them.
- The 4 failed frames per run in the spike's VT bench were not explained. The engine test that compares seeked frames against software decode will catch real corruption.
- Audio device behaviour (Bluetooth, device switches, multichannel downmix) cannot be verified while the user is away and tests must stay silent. It is logged and left for the user to check.
- HDR on-screen output, the mini player and fullscreen cannot be verified without showing a window; they need a hands-on check by the user.
- `ImageRenderer` shots approximate the material blur; they check layout, type and appearance, not the exact blur.
- (M2) The mini player (formerly Picture in Picture), media keys, Now Playing and the folder-access prompt cannot be exercised without a visible app; they are covered by unit tests of the wiring and need a hands-on check by the user.
- (M2) libass first-frame cost (46 ms in the spike) lands on the subtitle queue, never on the video path, but a track switch may show the new subtitle one frame late.
- (M3) Whether `AVSampleBufferDisplayLayer` honours `preferredDynamicRange` the way a plain `CALayer` does is not documented; if it ignores it, the layer behaves as AVPlayerLayer does (EDR for tagged HDR buffers) and the setting only affects screenshots. The hands-on check finds out; the plan and tests stay valid either way.
- (M3) The tone-mapping thresholds (203-nit patch at 190 to 250) assume Core Image's current curve; a macOS update may move values within the range, and the test checks properties rather than exact values for that reason.
- (M3) The energy bench measures a headless engine; the app adds SwiftUI and the window server. The hands-on QuickTime comparison is the real figure.
- (M3) Occlusion handling may make the first moment after revealing a window show the keyframe preview instead of the exact frame for up to 300 ms.
- (M3) Generated corruptions are not real-world damage; the corpus catches crashes and hangs, not every way a real broken file behaves.
- (M2) Real BluRay PGS tracks can be large (several MB per hour); they are not prefetched, so after a long seek a PGS line can appear up to one display set late.

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

M2 design pass (2026-10-24), also all mine:

- D26. Track and speed menus in the controller are SwiftUI panels on the controller's material, anchored above their buttons, not `NSMenu` or `NSPopover`: they match the chrome, show two-line rows with format tags, and render in the background screenshots. The menu bar carries the same items as native menus.
- D27. The controller widens to `clamp(0.45 x window width, 440, 600)` to fit previous, next, speed, subtitles, audio and the mini player button (then PiP); transport spacing 20 pt instead of 22; the volume slider widens to 104 pt on hover instead of 120; below 568 and 480 pt buttons drop in a fixed priority order.
- D28. Previous and next are hidden, not disabled, when the file is alone in its folder; disabled only at the ends of a season.
- D29. An external subtitle file beats an embedded track of the same language and rank.
- D30. Charset fallback for text subtitles: UTF-8, then Big5 if the file name or title says Traditional, else GB18030, then Latin-1 with an OSD.
- D31. Reel's default text style: PingFang SC Medium, size 45 on the 720-line reference, white, outline 2.5 (instead of M1's 1.5, which vanished on bright frames in the mockup), shadow 1.4 at 60%, bottom margin 40.
- D32. Bottom-aligned, unpositioned subtitle lines lift to 12 pt above the controller while it is visible and overlapping (0.25 s up, 0.35 s down after the chrome fades); positioned signs never move. IINA does not do this.
- D33. Unstyled text subtitles may use the black bars (`ass_set_use_margins`); ASS and bitmap subtitles stay in the video rect.
- D34. A background second demux pass collects every text subtitle event after open, so a line that started before the seek keyframe still shows after a seek.
- D35. The subtitle size factor applies to text subtitles only; PGS and DVD bitmaps are drawn as authored.
- D36. External VobSub (`.idx`/`.sub`) and `.sup` files are listed but disabled in M2, because the LGPL FFmpeg build has no `vobsub` or `sup` demuxer.
- D37. (Superseded 2026-10-26 by D70.) Subtitles were composited into the video frames while Picture in Picture was active.
- D38. Thumbnails: keyframes only, at most 400 per file, 384 x 216 JPEG in one pack per content key, 500 MB cache cap, generated coarse to fine on a separate demuxer and VideoToolbox session that pauses during seeks.
- D39. Auto-advance shows a card only at the end of the file, counts down 5 s, pauses while hovered, and uses a frame 30 s into the next episode as its thumbnail so the cold open is not shown.
- D40. The next episode inherits speed (for the session), subtitle and audio choice by language and title, changed delays and size, and volume; its own resume entry still wins.
- D41. In fullscreen the controller keeps its window size (600 pt) with its bottom 56 pt from the screen edge, and an "Ends at" wall-clock time shows at the top right; the clock is not shown in a window.
- D42. The mini player (formerly Picture in Picture) is Ctrl+Cmd+P (IINA's input.conf has no binding for it). The key table's delay rows now follow IINA's own file (Shift+Z / Shift+X / Shift+C for subtitles, ( ) _ for audio), correcting the M1 draft's lowercase z / x / c.
- D43. Cmd+S writes a PNG at the video's native size, with subtitles, to `~/Pictures/Reel/`, silently, confirmed by the OSD.
- D44. Reel registers with Now Playing only while a file is open, so it releases the media keys when idle.
- D45. Speed range 0.25 to 4 with presets 0.5 to 2; the speed carries across episodes within a session but resets to 1 on launch.
- D46. VP9 hybrid: software decode for exact seeks that cost more than 30 frames, hardware for playback and keyframe scrubs, hand-off at the next keyframe; acceptance at 800 ms p95 for the 4K60 fixture.
- D47. Secondary text is primary 68% in light (55% in dark) and checkmarks are primary rather than accent, after the impeccable critique measured 3.8:1 and 1.9:1 for the M1-style values on the light material.
- D48. Folder access goes through the standard usage strings; if the user denies it, episode navigation and sidecar subtitles quietly disappear and everything else works.
- D49. An active A-B loop or file loop disables auto-advance.

M3 design pass (2026-10-25), from the user-research P1s, also all mine:

- D50. HDR presentation stays with the system: Reel tags every decoded buffer completely and sets the display layer's `preferredDynamicRange`; the layer and window server do EDR, headroom changes, display moves and SDR tone mapping, as for QuickTime. No Metal renderer and no on-screen tone mapper of Reel's own.
- D51. A three-value setting, High dynamic range: Full (`.high`, default), Limited (`.constrainedHigh`), Off (`.standard`, the system tone-maps to SDR). SDR content is always `.standard`. Limited and Off are the remedy if a display dims the desktop.
- D52. Controller, panels, OSD and subtitles stay at SDR white: their layers are explicitly `.standard` with untagged sRGB contents. (The PiP compositing half of this decision went with D70.)
- D53. Screenshots, thumbnails, the next-episode image, Now Playing artwork and shot mode tone-map HDR to 8-bit sRGB through Core Image and ColorSync's PQ to SDR conversion (as built: identical to `AVAssetImageGenerator` for PQ; `CIToneMapHeadroom` put reference white at 188, under the floor). HLG is written as PQ first (the BT.2100 transcode at 1000 nits) and then goes through the same Apple PQ tone map, so HLG reference white is 229 like PQ's; that is about 74 codes brighter than QuickTime's own HLG conversion, which would fail the fixed floors of AC-M3-2 and AC-M3-9 (resolved in the third fix round, 7.7). No HDR or gain-map files.
- D54. Display headroom is read on screen-change notifications and polled at 2 Hz only while Video Info is open.
- D55. A dynamic range tag after the title (HDR10, HLG, Dolby Vision, with "SDR" when tone-mapped; none for SDR) that opens Video Info; Video Info is a read-only panel at the top right on Cmd+I, IINA's Inspector key.
- D56. Dolby Vision follows `dv_bl_signal_compatibility_id`: 1 and 6 play the HDR10 base, 4 the HLG base, 2 the SDR base; 0 (profile 5 and 10.0) plays the decoded base with a two-line note (until OK or 10 s) and a warning tag. No RPU reshaping in M3; a `reelctl probe --dovi-session` lets the user test VideoToolbox's own handling on a real file.
- D57. HDR is verified offline with generated lossless patch ramps (PQ and HLG; HEVC, AV1, VP9; Dolby Vision records inserted into the containers) and numeric checks of decoded codes, attachments, plans, tone-mapped values and layer properties; on-screen EDR, dimming and the external display are a short hands-on checklist for the user.
- D58. Paused means idle: no decode, no read-ahead polling, no periodic time events, no subtitle renders, thumbnails suspended 10 s after the last pointer movement, and the display sleep assertion and App Nap activity released.
- D59. While playing with the window (or, while it is up, the mini player panel) occluded for 1 s, video decode stops and audio continues; on reveal an exact seek to the clock time with the keyframe preview resyncs within 300 ms.
- D60. Every dispatch timer gets 10% leeway; Low Power Mode limits thumbnails to the coarse pass.
- D61. Energy is gated headless by `reelctl energy-bench` (`proc_pid_rusage` of Reel and of the `VTDecoderXPCService` it started, plus engine counters), with budgets per mode; the QuickTime comparison (at most 1.5 times its Energy Impact on the same mp4) is a hands-on Activity Monitor or Instruments check.
- D62. Damaged media never stops playback: bad packets are skipped to the next decodable frame with one OSD per region (at most one per 10 s) and a counter; truncated files keep the header duration with a faint missing tail and times counting to the end of the data.
- D63. Open failures show a failure card with one of six classified problems and fixed copy, replacing M1's error line; a disconnected drive pauses on the dimmed last frame and reopens automatically when the same volume and file come back.
- D64. Robustness is gated by a seeded generated corruption corpus plus odd files run through `reelctl soak` in isolated child processes (crash is a signal exit) with hang, descriptor and thread checks, an AddressSanitizer pass in acceptance, and a 12-file smoke subset plus the av-sync check as new `check.sh` gates.
- D65. The v key keeps toggling subtitle visibility, its OSD names the key, and visibility resets to shown for the next file.
- D66. Add Subtitle File gets Shift+Cmd+O (Reel's choice).
- D67. Output device: System Default or a device chosen by UID, in Settings and in the Audio menu, falling back to the system default with an OSD when it is missing. No passthrough or spatial audio work.
- D68. Settings gains only High dynamic range and Output device; energy behaviour is not a setting.
- D69. (Third fix round, for review.) VP9 played on VideoToolbox is checked for tile damage by a parse-only libavcodec pass (patched FFmpeg, the spec's zero-padding rule), held to 2% of one core on average; streams whose parse costs more are checked by whole GOPs as the budget allows. The alternative was no check (AC-M3-5 fails on one file) or a full check (about 23% of a core on 4K60 VP9). It is not a setting (D68).
- D70. Reel's own mini player replaces Apple's Picture in Picture (2026-10-26, owner's request after the macOS crop bug and the lag): a non-activating panel that borrows the window's video surface, so there is no second pipeline and no frame compositor. Design: `2026-10-26-reel-mini-player-design.md`.
