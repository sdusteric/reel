# Reel design

Date: 2026-10-24
Status: M1 shipped. M2 built (tasks M2-1 to M2-7 landed on 2026-10-24); `scripts/accept.sh offline` passes all six M2 criteria and all of M1 (see "M2 status" in section 16). Earlier status: approved for M1 by the planner (the user is away and opted out of questions; every decision below is the planner's and is listed for review in "Decisions to review"). M2 design pass done on 2026-10-24 (sections 8, 9.3 to 9.12, 10, 15.2 and 16; mockups in `docs/mockup/`); its calls are D26 to D49.

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
- **Lift above the controller.** While the controller is visible and its frame intersects the band where bottom-aligned lines are drawn, those lines move up so their bottom edge sits 12 pt above the controller's top edge. Only bottom-aligned events without `\pos` or `\move` move (libass `ass_set_line_position`); signs and positioned karaoke stay. Bitmap subtitles whose bounding box is in the bottom third move as one image. The move animates 0.25 s ease-out when the chrome appears and goes back 0.35 s ease-in-out after the chrome has finished fading out; with Reduce Motion it is a 0.1 s cross-fade **(my call; IINA does not lift, YouTube does)**. If the user dragged the controller away from the bottom, nothing moves.
- Fullscreen uses the same rules on the display's size (mockup `png/15`).

### 8.6 Rendering and timing

- The subtitle clock is the synchronizer's time minus the subtitle delay. A `CADisplayLink`-paced render (at most once per display frame, normally 30 Hz while text is changing, idle otherwise) calls `ass_render_frame` at the window's pixel size. `changed == 0` skips everything; `changed == 1` (same bitmaps, moved) reuses the blended image with a new position; `changed == 2` re-blends.
- Blending: the `ASS_Image` list is composited into one premultiplied BGRA bitmap covering the union of the images' rects (the dirty rect, typically 1500 x 160 px for two lines at 1080), then set as `contents` of a `CALayer` above the display layer, with `contentsScale` equal to the window's backing scale. Bitmap subtitles use the same layer.
- Delay: Shift+Z / Shift+X step 0.5 s, Alt+Shift+Z / Alt+Shift+X step 0.1 s, Shift+C resets (IINA's bindings, section 10). Delay applies to text and bitmap tracks alike.
- Seeking: on `.scrub(t)` the subtitle shown is the one at t (from the prefetched events), so scrubbing shows the right line next to the keyframe preview. On `.exact(t)` it updates when the target frame lands, never before, so text and picture change together.
- Next and previous line (Shift+Right / Shift+Left): an exact seek to the start of the next or previous text event of the selected track (`ass_step_sub`), using the prefetched events.
- Screenshots (Cmd+S) include the subtitles, composited at the video's native resolution (IINA's default `screenshot` includes them).
- Picture in Picture: the PiP window shows only the display layer, so subtitles would vanish. While PiP is active and a subtitle is visible, the engine composites the subtitle bitmap onto a pooled copy of each video frame (Core Image source-over on the GPU) before enqueueing; frames without a visible subtitle pass through untouched **(my call; if this cannot hold 60 fps at 4K, M2 ships PiP without subtitles for 4K and logs it)**.

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
- Picture in Picture (M2, section 9.9): `AVPictureInPictureController` with `ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` on the existing display layer.
- Display sleep: `IOPMAssertionCreateWithName(PreventUserIdleDisplaySleep, "Reel is playing video")` while playing, released on pause, close and quit.

### 9.2 Chrome visibility

- The traffic lights, title and controller share one `chromeVisible` state.
- Shown on pointer movement of 2 pt or more inside the window, on any key that changes playback (shown for the auto-hide period), and always while paused.
- Hidden after 2.5 s without input while playing. Never hidden while the pointer is over the controller or a drag is in progress.
- The cursor hides with the chrome (`NSCursor.setHiddenUntilMouseMoves(true)`) only when the pointer is over the video.
- Fade in 0.22 s ease-out, fade out 0.35 s ease-in. Traffic lights fade through `standardWindowButton(_:)?.animator().alphaValue` in the same transaction. With Reduce Motion: opacity only, 0.1 s.

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
  - Right cluster, flush right: speed label button (min 36 pt wide), 6 pt, subtitles, audio, Picture in Picture, fullscreen (28 pt hit targets, no gaps; the glyphs are 17 pt so the visual gap is 11 pt).
  - Previous and next are hidden when the file is alone in its folder, and the transport re-centres; previous is disabled (55%) on the first episode and next on the last (mockup `png/18`).
  - Below 568 pt of controller width the controller drops previous, next and Picture in Picture (they stay in the menus and keys); below 480 pt it also drops the audio button and the speed label. Priority from first kept to first dropped: play/pause, back and forward 10, fullscreen, volume, subtitles, audio, speed, next, previous, PiP.
  - Subtitle glyph: `captions.bubble.fill` while a subtitle track is on, `captions.bubble` while off. Audio: `waveform`. PiP: `pip.enter`, and `pip.exit` in the accent colour while PiP is active. Speed: the current rate as text ("1×", "1.5×", 13 pt semibold rounded, monospaced digits); when the rate is not 1 it turns accent on an accent 16 to 22% capsule so a changed speed is never missed.
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
- Drag on the video moves the window. Right click: context menu with Open, Play/Pause, Show in Finder. M2 adds Subtitles and Audio submenus (the same items as the menu bar), Speed, Take Screenshot and Picture in Picture.
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

### 9.9 Picture in Picture (M2)

- Started from the controller button, the Video menu or Ctrl+Cmd+P. `AVPictureInPictureController` with the sample buffer display layer content source; the playback delegate maps play, pause, skip by interval (10 s) and the time range to the engine.
- The main window keeps its size and shows the PiP state (mockup `png/16`): the frame at the moment PiP started, blurred (48 pt radius) and darkened to 42% brightness, a 60 pt tile with the PiP glyph, "Playing in Picture in Picture" (15 pt semibold, white 78%), "Playback controls here still work." (12 pt, white 50%), and an "Exit Picture in Picture" capsule button. The controller and title keep working; the PiP button shows `pip.exit` in the accent colour.
- Subtitles are composited into the frames while PiP is active (8.6).
- Closing the main window while PiP is active stops PiP and closes the file (one window, one file).

### 9.10 Now Playing and media keys (M2)

- `MPNowPlayingInfoCenter` while a file is open: title = episode name (9.8) or the stem, duration, elapsed time, playback rate, and the current thumbnail as artwork. Updated on play, pause, seek settle, rate change and every 5 s, never on every time tick. Cleared on close, so Reel stops claiming the media keys when nothing is open.
- `MPRemoteCommandCenter`: play, pause, toggle play/pause, next track and previous track (next and previous episode), change playback position (exact seek), skip forward and back 10 s. Media keys reach Reel through these, so they also work while Reel is in the background, which is how macOS media keys behave.

### 9.11 Menu bar (M2)

Native `NSMenu`s, mockup `png/17`. Items with a Command or Control shortcut show it; plain-key bindings stay out of the menus as in M1 (the content view handles them, so they never fire twice).

- Playback: Play/Pause; Forward 5 Seconds, Back 5 Seconds; Next Frame, Previous Frame; separator; Next Episode (Cmd+Right), Previous Episode (Cmd+Left), Auto-Advance to Next Episode (checkmark, on); separator; Speed submenu (Double Cmd+], Half Cmd+[, Faster Alt+Cmd+], Slower Alt+Cmd+[, Normal Cmd+\, then the presets with a checkmark); separator; Set Loop Start / Set Loop End / Clear Loop (one item whose title follows the state, Cmd+L), Loop File (checkmark, Shift+Cmd+L).
- Video: Half Size, Actual Size, Double Size, Fit to Screen (Cmd+0 to 3); Enter Full Screen (Ctrl+Cmd+F); Enter Picture in Picture (Ctrl+Cmd+P); Video Track submenu and Next Video Track (Ctrl+Cmd+V, disabled with one video track); Take Screenshot (Cmd+S); Show Screenshots in Finder.
- Audio: the audio tracks with a checkmark; Next Audio Track (Ctrl+Cmd+A); Volume Up, Volume Down, Mute (Cmd+/); Increase Audio Delay, Decrease Audio Delay, Reset Audio Delay (disabled at 0).
- Subtitles: Off and the subtitle tracks with a checkmark (disabled items for unsupported external files, with the reason as a tooltip); Next Subtitle Track (Ctrl+Cmd+S); Add Subtitle File; Show Subtitles (checkmark); Delay submenu (Increase, Decrease, Reset); Size and Position submenu (Larger, Smaller, Move Up, Move Down, Reset).

### 9.12 Screenshot, loops and document types (M2)

- Cmd+S saves the current frame at the video's native size, with subtitles, as PNG to `~/Pictures/Reel/<stem> <hh-mm-ss>.png` (`REEL_SCREENSHOTS` overrides the folder; without it, a set `REEL_HOME` puts screenshots in `REEL_HOME/Screenshots`, so tests and tools with a temp home never write to ~/Pictures). Taken from the last landed decoded frame (`FrameGrabber.image(from:)`), so it never waits for a decode. No sound, no flash; the OSD confirms.
- A-B loop (Cmd+L): first press sets A at the current time, second sets B, third clears. Reaching B issues an exact seek to A, which is a store hit and lands in one GOP decode. B before A swaps them. File loop (Shift+Cmd+L): at the end, exact seek to 0 instead of ending; disables auto-advance while on.
- Default app: `CFBundleDocumentTypes` with role Viewer and rank Default for mp4, m4v, mov, mkv, webm, avi, flv, ts, m2ts, mts, ogv and the audio types; `UTImportedTypeDeclarations` for the types macOS does not declare (`org.matroska.mkv`, `org.webmproject.webm`, `com.adobe.flash-video`, `public.avi` where missing). The user sets Reel as the default player in Finder themselves; Reel never calls LaunchServices to claim it.
- Folder access: the episode list and external subtitles need to list the file's folder. Reel is not sandboxed, so macOS asks once per protected location (Documents, Downloads, Desktop, removable volumes). Info.plist carries `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSDesktopFolderUsageDescription` and `NSRemovableVolumesUsageDescription` ("Reel lists the other videos and subtitle files in the folder of the video you open."). If access is denied, the episode buttons hide and only embedded subtitles are offered; nothing else breaks. Tests and shots never trigger the prompt: they only list folders inside the repo's `build/fixtures` (or a `mktemp` dir), from the agent's shell, which already has access to them.

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
| v (M2) | Show / hide subtitles |
| r / Shift+R, t (M2) | Move subtitles up / down by 1% |
| Shift+G / Shift+F (M2) | Subtitle size +10% / -10% (45 to 50, 45 to 40) |
| Ctrl+Cmd+S / Ctrl+Cmd+A / Ctrl+Cmd+V (M2) | Cycle subtitle / audio / video track |
| Ctrl+Cmd+P (M2) | Picture in Picture (Reel's choice; IINA's input.conf has no binding) |
| Cmd+S (M2) | Screenshot to ~/Pictures/Reel |
| Cmd+L (M2) | A-B loop: set A, set B, clear |
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
| `REEL_HOME/settings.json` | the four settings |
| `REEL_HOME/state.json` | volume, remaining-time toggle, window frame, controller fractions |
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
     ThumbnailCache, Screenshot, PiPFrameCompositor; ReelUI adds TrackPanels, SpeedPanel, ThumbnailPill,
     NextEpisodeCard, PiPPlaceholder, SubtitleOverlay, AutoAdvance; Reel adds NowPlaying,
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

## 15. Visual design

### 15.1 Base (M1)

- The video area is always black in both appearances. The chrome follows the system appearance through standard materials and semantic colours (`.primary`, `.secondary`, accent for the played track only). Nothing is forced dark.
- Title bar: no material band. A black gradient scrim (50% at the top, easing to clear over 68 pt) sits behind the white title so the picture runs to the top edge and the title stays legible on bright frames.
- Typography: SF Pro throughout. Times 12 pt medium monospaced digits; hover pill 12 pt semibold; OSD 20 pt semibold rounded; title 13 pt semibold, centred in the title bar area, white at 88% with a faint shadow, fading with the chrome; empty state 15 pt semibold.
- Spacing: controller padding 14 x 12, 22 pt between transport buttons, 12 pt between the time labels and the seek bar, 16 pt minimum margin from window edges.
- Motion: chrome fade 0.22 s in, 0.35 s out; track grow spring 0.18 s; hover backgrounds 0.12 s; button press 0.1 s; OSD 0.12 s in, 0.25 s out; controller drag follows directly with no animation; window resize for a new video animates 0.2 s keeping its centre. Reduce Motion: opacity only, 0.1 s.
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

**Type** (SF Pro; rounded where noted): panel header 13 semibold, count 11 medium; row label 13 medium; row detail 11.5 regular (Chinese titles in PingFang SC at the same size); tag 10.5 semibold with +3% tracking; speed label 13 semibold rounded with monospaced digits; speed presets 12 semibold rounded; stepper values 13 medium monospaced digits; next card title 13 semibold, episode name 13 medium, countdown 12 medium monospaced digits; capsule buttons 12 semibold; PiP placeholder 15 semibold and 12 regular; fullscreen end time 12 medium. OSD stays 20 semibold rounded.

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
| PiP placeholder | tile 60 (radius 16, white 10% fill, white 14% hairline, glyph 28 at white 62%), 18 pt to the title, 6 to the line, 16 to the button; backdrop blur 48, brightness 42% |
| Subtitles | 8.4 and 8.5: size 45 on the 720 reference, outline 2.5, shadow 1.4 down, margin 40, lift to 12 pt above the controller |

**Motion.** From a `find-animation-opportunities` pass over the M2 surfaces, gated on frequency, purpose, budget and function. Curves: ease-out is `cubic-bezier(0.23, 1, 0.32, 1)` (SwiftUI `.timingCurve(0.23, 1, 0.32, 1, duration:)`), ease-in is `(0.4, 0, 1, 1)`, ease-in-out is `(0.65, 0, 0.35, 1)`. With Reduce Motion every movement below becomes an opacity change of 0.1 s.

| Surface | What moves | Duration and curve | Purpose |
|---|---|---|---|
| Track and speed panels, open | opacity 0 to 1 and scale 0.96 to 1, anchored at the button (bottom centre) | 0.16 s ease-out | spatial: it grows from the button that opened it |
| Panels, close | opacity only | 0.12 s ease-in | quick exit, nothing to follow |
| Thumbnail image arriving under a resting pointer | opacity | 0.12 s ease-out | no pop-in |
| Speed button when the rate leaves or returns to 1 | colour and capsule fill | 0.15 s ease-in-out | state change is noticed |
| A-B marks set or cleared | opacity | 0.12 s ease-out | state |
| Subtitle lift up | bottom lines translate up | 0.25 s ease-out, starting with the chrome fade-in | keeps text readable without a jump |
| Subtitle lift down | translate back | 0.35 s ease-in-out, after the chrome fade-out ends | text never moves under a fading controller |
| Next card, enter | opacity and translate y 12 to 0 | 0.32 s ease-out | a rare, end-of-episode moment |
| Next card, exit | same path back | 0.2 s ease-in | symmetric exit |
| Countdown ring | stroke end 0 to 1 | 5 s linear, paused while hovered | state (time left) |
| PiP placeholder | opacity | 0.2 s ease-out in, 0.15 s ease-in out; the system animates the video itself | bridge while the picture leaves |

Rejected, on purpose: OSD text on repeated key presses (changes in place, M1 rule; keyboard actions run hundreds of times); keyboard track cycling (OSD only, no panel); individual subtitle lines (never animated by Reel; ASS `\fad` stays authored); the thumbnail pill following the pointer (1:1, no smoothing); switching episodes (the old frame stays until the new first frame, like a seek; no cross-fade); controller relayout on window resize (resizing is direct manipulation); the speed preset selection (instant).

**Accessibility.** Hit targets at least 28 pt (play 32, steppers 30 x 26, panel rows 30). Every control has an accessibility label and value ("Subtitles, Chinese (Simplified)", "Speed, 1.5 times"). Measured in the mockup: controller times 8.2:1 (light) and 10.9:1 (dark); panel labels 9.0:1 and 11.9:1. With Reduce Transparency the materials become `windowBackgroundColor` at 96% with the same hairline. Subtitle white on its black outline is about 21:1 whatever the frame.

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
- Picture in Picture with the sample buffer layer content source, subtitles composited while active, a main-window placeholder.
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

## 17. Risks

- Real files are heavier than the noise fixtures; real-world exact seeks will be slower than the bench. The keyframe preview is the mitigation, and M2 thumbnails add another.
- Requesting `420v`/`x420` from VideoToolbox may cost bandwidth at 4K60 versus the native compressed formats. If 4K60 playback drops frames, try the native formats and verify the layer accepts them.
- The 4 failed frames per run in the spike's VT bench were not explained. The engine test that compares seeked frames against software decode will catch real corruption.
- Audio device behaviour (Bluetooth, device switches, multichannel downmix) cannot be verified while the user is away and tests must stay silent. It is logged and left for the user to check.
- HDR on-screen output, PiP start and fullscreen cannot be verified without showing a window; they need a hands-on check by the user.
- `ImageRenderer` shots approximate the material blur; they check layout, type and appearance, not the exact blur.
- (M2) Picture in Picture, media keys, Now Playing and the folder-access prompt cannot be exercised without a visible app; they are covered by unit tests of the wiring and need a hands-on check by the user.
- (M2) libass first-frame cost (46 ms in the spike) lands on the subtitle queue, never on the video path, but a track switch may show the new subtitle one frame late.
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
- D27. The controller widens to `clamp(0.45 x window width, 440, 600)` to fit previous, next, speed, subtitles, audio and PiP; transport spacing 20 pt instead of 22; the volume slider widens to 104 pt on hover instead of 120; below 568 and 480 pt buttons drop in a fixed priority order.
- D28. Previous and next are hidden, not disabled, when the file is alone in its folder; disabled only at the ends of a season.
- D29. An external subtitle file beats an embedded track of the same language and rank.
- D30. Charset fallback for text subtitles: UTF-8, then Big5 if the file name or title says Traditional, else GB18030, then Latin-1 with an OSD.
- D31. Reel's default text style: PingFang SC Medium, size 45 on the 720-line reference, white, outline 2.5 (instead of M1's 1.5, which vanished on bright frames in the mockup), shadow 1.4 at 60%, bottom margin 40.
- D32. Bottom-aligned, unpositioned subtitle lines lift to 12 pt above the controller while it is visible and overlapping (0.25 s up, 0.35 s down after the chrome fades); positioned signs never move. IINA does not do this.
- D33. Unstyled text subtitles may use the black bars (`ass_set_use_margins`); ASS and bitmap subtitles stay in the video rect.
- D34. A background second demux pass collects every text subtitle event after open, so a line that started before the seek keyframe still shows after a seek.
- D35. The subtitle size factor applies to text subtitles only; PGS and DVD bitmaps are drawn as authored.
- D36. External VobSub (`.idx`/`.sub`) and `.sup` files are listed but disabled in M2, because the LGPL FFmpeg build has no `vobsub` or `sup` demuxer.
- D37. Subtitles are composited into the video frames only while Picture in Picture is active (PiP shows only the display layer); if 4K cannot keep up, 4K PiP runs without subtitles and logs it.
- D38. Thumbnails: keyframes only, at most 400 per file, 384 x 216 JPEG in one pack per content key, 500 MB cache cap, generated coarse to fine on a separate demuxer and VideoToolbox session that pauses during seeks.
- D39. Auto-advance shows a card only at the end of the file, counts down 5 s, pauses while hovered, and uses a frame 30 s into the next episode as its thumbnail so the cold open is not shown.
- D40. The next episode inherits speed (for the session), subtitle and audio choice by language and title, changed delays and size, and volume; its own resume entry still wins.
- D41. In fullscreen the controller keeps its window size (600 pt) with its bottom 56 pt from the screen edge, and an "Ends at" wall-clock time shows at the top right; the clock is not shown in a window.
- D42. Picture in Picture is Ctrl+Cmd+P (IINA's input.conf has no binding for it). The key table's delay rows now follow IINA's own file (Shift+Z / Shift+X / Shift+C for subtitles, ( ) _ for audio), correcting the M1 draft's lowercase z / x / c.
- D43. Cmd+S writes a PNG at the video's native size, with subtitles, to `~/Pictures/Reel/`, silently, confirmed by the OSD.
- D44. Reel registers with Now Playing only while a file is open, so it releases the media keys when idle.
- D45. Speed range 0.25 to 4 with presets 0.5 to 2; the speed carries across episodes within a session but resets to 1 on launch.
- D46. VP9 hybrid: software decode for exact seeks that cost more than 30 frames, hardware for playback and keyframe scrubs, hand-off at the next keyframe; acceptance at 800 ms p95 for the 4K60 fixture.
- D47. Secondary text is primary 68% in light (55% in dark) and checkmarks are primary rather than accent, after the impeccable critique measured 3.8:1 and 1.9:1 for the M1-style values on the light material.
- D48. Folder access goes through the standard usage strings; if the user denies it, episode navigation and sidecar subtitles quietly disappear and everything else works.
- D49. An active A-B loop or file loop disables auto-advance.
