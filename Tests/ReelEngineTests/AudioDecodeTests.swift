import AVFoundation
import CoreMedia
import CReelDeps
import Foundation
import ReelCore
import Testing
@testable import ReelEngine

// These tests check decoded buffers and timestamps only. None of them creates an
// AVSampleBufferAudioRenderer: the AudioOutput suite tests the attach policy, never an attach.

/// Fixture lookup by file name, through the shared `Fixture` helper.
enum AudioTestMedia {
    static func fixture(_ name: String) throws -> URL {
        try #require(Fixture(rawValue: name), "unknown fixture \(name)").url()
    }
}

/// Reads the best audio stream of a file with libavformat, the way the demuxer feeds the decoder.
final class AudioFixtureReader {
    private var format: UnsafeMutablePointer<AVFormatContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    let stream: UnsafeMutablePointer<AVStream>
    let streamIndex: Int32

    init(url: URL) throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_open_input(&context, url.path(percentEncoded: false), nil, nil), "avformat_open_input")
        format = context
        try FFmpegError.check(avformat_find_stream_info(context, nil), "avformat_find_stream_info")
        let index = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        try FFmpegError.check(index, "av_find_best_stream")
        guard let context, let found = context.pointee.streams[Int(index)] else { throw EngineError.noPlayableStream }
        stream = found
        streamIndex = index
        packet = av_packet_alloc()
    }

    deinit {
        av_packet_free(&packet)
        avformat_close_input(&format)
    }

    var timeBase: AVRational { stream.pointee.time_base }

    func makeDecoder() throws -> AudioDecoder {
        try AudioDecoder(stream: stream)
    }

    /// The next packet of the audio stream, valid until the next call; nil at end of file.
    func nextPacket() -> UnsafeMutablePointer<AVPacket>? {
        guard let format, let packet else { return nil }
        while true {
            av_packet_unref(packet)
            if av_read_frame(format, packet) < 0 { return nil }
            if packet.pointee.stream_index == streamIndex { return packet }
        }
    }

    /// Seeks the file (default stream, so the video keyframe for files with video) to at or before `time`.
    func seek(to time: MediaTime) throws {
        let timestamp = time.value(timeBaseNum: 1, timeBaseDen: reel_av_time_base())
        try FFmpegError.check(av_seek_frame(format, -1, timestamp, AVSEEK_FLAG_BACKWARD), "av_seek_frame")
    }

    func packetEnd(_ packet: UnsafePointer<AVPacket>) -> MediaTime? {
        let pts = packet.pointee.pts != reel_av_nopts() ? packet.pointee.pts : packet.pointee.dts
        guard pts != reel_av_nopts() else { return nil }
        return MediaTime(value: pts + packet.pointee.duration, timeBaseNum: timeBase.num, timeBaseDen: timeBase.den)
    }
}

enum AudioTestSupport {
    /// A decoder for a fixture's audio stream that no other value refers to, so it can be sent
    /// to an `AudioDecodeThread`.
    static func makeDecoder(_ name: String) throws -> sending AudioDecoder {
        let reader = try AudioFixtureReader(url: try AudioTestMedia.fixture(name))
        return try AudioDecoder(codecParameters: try #require(reader.stream.pointee.codecpar), timeBase: reader.timeBase)
    }

    /// Decodes the whole audio stream from the start.
    static func decodeAll(_ name: String) throws -> (decoder: AudioDecoder, buffers: [DecodedAudioBuffer]) {
        let reader = try AudioFixtureReader(url: try AudioTestMedia.fixture(name))
        let decoder = try reader.makeDecoder()
        var buffers: [DecodedAudioBuffer] = []
        while let packet = reader.nextPacket() {
            buffers += try decoder.decode(packet)
        }
        buffers += try decoder.finish()
        return (decoder, buffers)
    }

    /// Seeks like the engine (design 7.5 step 6): packets from `target` minus the preroll, decoder
    /// reset with trimming at `target`, then decode `length` of audio.
    static func decode(
        reader: AudioFixtureReader,
        decoder: AudioDecoder,
        from target: MediaTime,
        length: MediaTime
    ) throws -> [DecodedAudioBuffer] {
        let start = target - decoder.preroll
        try reader.seek(to: start)
        decoder.reset(dropBefore: target)
        var buffers: [DecodedAudioBuffer] = []
        while let packet = reader.nextPacket() {
            if let end = reader.packetEnd(packet), end <= start { continue }
            buffers += try decoder.decode(packet)
            if let last = buffers.last, last.end >= target + length { break }
        }
        return buffers
    }

    /// Times where channel 0 rises above `threshold` after at least `silence` below it.
    static func beepOnsets(
        _ buffers: [DecodedAudioBuffer],
        threshold: Float = 0.1,
        silence: MediaTime = .milliseconds(8)
    ) -> [MediaTime] {
        guard let first = buffers.first else { return [] }
        let rate = first.sampleRate
        let quietNeeded = Int(Int64(rate) * silence.microseconds / 1_000_000)
        var onsets: [MediaTime] = []
        var quietRun = quietNeeded // the start of the data counts as quiet
        var lastIndex: Int64?
        for buffer in buffers {
            if let lastIndex, buffer.startSample != lastIndex { quietRun = quietNeeded }
            let samples = buffer.interleavedSamples()
            for frame in 0..<buffer.frameCount {
                let value = abs(samples[frame * buffer.channelCount])
                if value > threshold {
                    if quietRun >= quietNeeded {
                        onsets.append(MediaTime(value: buffer.startSample + Int64(frame), timeBaseNum: 1, timeBaseDen: Int32(rate)))
                    }
                    quietRun = 0
                } else {
                    quietRun += 1
                }
            }
            lastIndex = buffer.startSample + Int64(buffer.frameCount)
        }
        return onsets
    }

    /// Distance from `time` to the nearest whole second.
    static func offsetFromWholeSecond(_ time: MediaTime) -> MediaTime {
        let nearest = (time.microseconds + 500_000) / 1_000_000 * 1_000_000
        return MediaTime(microseconds: abs(time.microseconds - nearest))
    }

    /// Indices where a buffer does not start where the previous one ended.
    static func gaps(_ buffers: [DecodedAudioBuffer]) -> [Int] {
        guard buffers.count > 1 else { return [] }
        return (1..<buffers.count).filter { buffers[$0].startSample != buffers[$0 - 1].startSample + Int64(buffers[$0 - 1].frameCount) }
    }
}

/// Synthetic pcm_f32le packets, so frame sizes, timestamps and sample values are exact.
final class SyntheticPCMStream {
    let sampleRate: Int
    let channels: Int
    let timeBase: AVRational
    private var parameters: UnsafeMutablePointer<AVCodecParameters>?

    init(sampleRate: Int = 48_000, channels: Int = 2, timeBase: AVRational = AVRational(num: 1, den: 48_000)) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.timeBase = timeBase
        parameters = avcodec_parameters_alloc()
        if let parameters {
            parameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
            parameters.pointee.codec_id = AV_CODEC_ID_PCM_F32LE
            parameters.pointee.sample_rate = Int32(sampleRate)
            parameters.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
            av_channel_layout_default(&parameters.pointee.ch_layout, Int32(channels))
        }
    }

    deinit {
        avcodec_parameters_free(&parameters)
    }

    func makeDecoder() throws -> AudioDecoder {
        let parameters = try #require(parameters)
        return try AudioDecoder(codecParameters: parameters, timeBase: timeBase)
    }

    /// A packet of `frames` frames whose channel-0 samples count up from `firstValue`, with pts
    /// `ptsSample` (in samples) expressed in the stream time base.
    func packet(frames: Int, ptsSample: Int64?, firstValue: Float) throws -> UnsafeMutablePointer<AVPacket> {
        let packet = try #require(av_packet_alloc())
        try FFmpegError.check(av_new_packet(packet, Int32(frames * channels * 4)), "av_new_packet")
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                samples[frame * channels + channel] = channel == 0 ? firstValue + Float(frame) : -1
            }
        }
        samples.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                packet.pointee.data.update(from: base.assumingMemoryBound(to: UInt8.self), count: raw.count)
            }
        }
        if let ptsSample {
            packet.pointee.pts = av_rescale_q(ptsSample, AVRational(num: 1, den: Int32(sampleRate)), timeBase)
        } else {
            packet.pointee.pts = reel_av_nopts()
        }
        packet.pointee.dts = packet.pointee.pts
        packet.pointee.duration = av_rescale_q(Int64(frames), AVRational(num: 1, den: Int32(sampleRate)), timeBase)
        return packet
    }

    /// Decodes `count` packets of `frames` frames each, contiguous from sample `start`.
    func decodeContiguous(_ decoder: AudioDecoder, packets count: Int, frames: Int, start: Int64 = 0) throws -> [DecodedAudioBuffer] {
        var buffers: [DecodedAudioBuffer] = []
        for index in 0..<count {
            let first = start + Int64(index * frames)
            var packet: UnsafeMutablePointer<AVPacket>? = try self.packet(frames: frames, ptsSample: first, firstValue: Float(first))
            defer { av_packet_free(&packet) }
            buffers += try decoder.decode(try #require(packet))
        }
        return buffers
    }
}

@Suite struct AudioDecodeTests {
    static let fixturesWithAudio = [
        "sync_h264_aac.mp4", "sync_hevc_opus.mkv", "hevc10_1080p24.mkv", "h264_1080p30.mp4",
        "av1_2160p60.mkv", "mpeg4.avi", "flv1.flv", "annexb_h264.ts", "rot90_h264.mov",
    ]

    @Test(arguments: fixturesWithAudio)
    func decodesFixtureAudioIntoContiguousFloatBuffers(_ name: String) throws {
        let (decoder, buffers) = try AudioTestSupport.decodeAll(name)
        #expect(!buffers.isEmpty)
        #expect(decoder.corruptPackets == 0)
        #expect(AudioTestSupport.gaps(buffers).isEmpty, "timestamps continue across buffers")

        let first = try #require(buffers.first)
        let description = try #require(first.sampleBuffer.formatDescription)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatLinearPCM)
        #expect(asbd.mFormatFlags == kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        #expect(asbd.mBitsPerChannel == 32)
        #expect(asbd.mChannelsPerFrame == UInt32(decoder.channelCount))
        #expect(asbd.mBytesPerFrame == UInt32(4 * decoder.channelCount))
        #expect(Int(asbd.mSampleRate) == decoder.sampleRate)
        for buffer in buffers {
            #expect(buffer.sampleBuffer.presentationTimeStamp == buffer.presentationTime)
            #expect(buffer.sampleBuffer.withUnsafeSampleBuffer { CMSampleBufferGetNumSamples($0) } == buffer.frameCount)
        }
    }

    @Test func coalescesBuffersToAtLeastTwentyMilliseconds() throws {
        for name in ["sync_h264_aac.mp4", "sync_hevc_opus.mkv", "hevc10_1080p24.mkv"] {
            let (_, buffers) = try AudioTestSupport.decodeAll(name)
            for buffer in buffers.dropLast() {
                #expect(buffer.duration >= .milliseconds(20), "\(name) buffer at \(buffer.pts) is \(buffer.duration)")
            }
        }
    }

    @Test func coalescesTinyTrueHDSizedFramesIntoTwentyMillisecondBuffers() throws {
        let stream = SyntheticPCMStream()
        let decoder = try stream.makeDecoder()
        var buffers = try stream.decodeContiguous(decoder, packets: 100, frames: 40)
        buffers += try decoder.finish()
        // 4000 frames at 48 kHz: four buffers of 960 frames (24 packets each) and a 160-frame tail.
        #expect(buffers.map(\.frameCount) == [960, 960, 960, 960, 160])
        #expect(AudioTestSupport.gaps(buffers).isEmpty)
        let samples = buffers.flatMap { $0.interleavedSamples() }
        let channelZero = stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
        #expect(channelZero == (0..<4000).map { Float($0) }, "samples arrive in order, interleaved")
        #expect(samples[1] == -1)
    }

    @Test func decodesOnTheDedicatedThreadAndDropsStaleGenerations() async throws {
        let reader = try AudioFixtureReader(url: try AudioTestMedia.fixture("sync_hevc_opus.mkv"))
        let thread = AudioDecodeThread(decoder: try AudioTestSupport.makeDecoder("sync_hevc_opus.mkv"))
        defer { thread.stop() }

        for _ in 0..<50 {
            guard let raw = reader.nextPacket() else { break }
            thread.submit(Packet(moving: raw, timeBase: reader.timeBase), generation: 0)
        }
        let target = MediaTime.seconds(10)
        try reader.seek(to: target - thread.preroll)
        thread.seek(dropBefore: target, generation: 1)
        thread.submit(Packet(moving: try #require(reader.nextPacket()), timeBase: reader.timeBase), generation: 0)
        while let raw = reader.nextPacket() {
            let end = reader.packetEnd(raw)
            thread.submit(Packet(moving: raw, timeBase: reader.timeBase), generation: 1)
            if let end, end >= target + .seconds(3) { break }
        }
        thread.finish(generation: 1)

        var current: [DecodedAudioBuffer] = []
        loop: for await output in thread.outputs {
            switch output {
            case .buffer(let buffer, let generation):
                if generation == 1 { current.append(buffer) }
            case .endOfStream(let generation):
                if generation == 1 { break loop }
            case .failed(let message, _):
                Issue.record("decode failed: \(message)")
                break loop
            }
        }
        let first = try #require(current.first)
        #expect(first.pts == target)
        #expect(AudioTestSupport.gaps(current).isEmpty)
        let decoded = current.reduce(MediaTime.zero) { $0 + $1.duration }
        #expect(decoded >= .seconds(2.9), "decoded \(decoded) after the seek")
    }

    @Test func prerollIsEightyMillisecondsForOpusAndOneFrameOtherwise() throws {
        #expect(AudioDecoder.preroll(codecID: AV_CODEC_ID_OPUS, frameSize: 960, sampleRate: 48_000) == .milliseconds(80))
        #expect(AudioDecoder.preroll(codecID: AV_CODEC_ID_AAC, frameSize: 1024, sampleRate: 48_000) == .microseconds(21_333))
        #expect(AudioDecoder.preroll(codecID: AV_CODEC_ID_AC3, frameSize: 0, sampleRate: 48_000) == .milliseconds(32))
        let opus = try AudioFixtureReader(url: try AudioTestMedia.fixture("sync_hevc_opus.mkv")).makeDecoder()
        #expect(opus.preroll == .milliseconds(80))
        let aac = try AudioFixtureReader(url: try AudioTestMedia.fixture("sync_h264_aac.mp4")).makeDecoder()
        #expect(aac.preroll == .microseconds(21_333))
    }
}

@Suite struct AudioOutputPolicyTests {
    @Test func testsAndHeadlessToolsNeverGetAnAudibleRenderer() {
        #expect(AudioOutput.attachDecision(mode: .headless, allowsAudio: false, isTestProcess: false) == .none)
        #expect(AudioOutput.attachDecision(mode: .headless, allowsAudio: true, isTestProcess: false) == .silent)
        #expect(AudioOutput.attachDecision(mode: .playback, allowsAudio: false, isTestProcess: true) == .none)
        #expect(AudioOutput.attachDecision(mode: .playback, allowsAudio: true, isTestProcess: true) == .silent)
        #expect(AudioOutput.attachDecision(mode: .playback, allowsAudio: false, isTestProcess: false) == .audible)
    }

    @Test func thisTestProcessIsRecognisedAsATestRun() {
        #expect(AudioOutput.isTestProcess())
        #expect(!AudioOutput.isTestProcess(environment: ["HOME": "/tmp"], processName: "Reel"))
        #expect(AudioOutput.isTestProcess(environment: [:], processName: "xctest"))
    }

    @Test func headlessAttachReturnsNilWithoutAllowAudio() {
        // Returns before creating a renderer, so nothing is attached to the synchronizer.
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let output = AudioOutput.attach(to: synchronizer, mode: .headless, environment: ReelEnvironment(["REEL_HOME": "/tmp/none"]))
        #expect(output == nil)
    }

    @Test func volumeUsesTheCubicCurveAndSilentModeStaysMuted() {
        let audible = AudioOutput.rendererSettings(volume: 47, muted: false, decision: .audible)
        #expect(abs(audible.gain - 0.103823) < 0.000001)
        #expect(!audible.muted)
        #expect(AudioOutput.rendererSettings(volume: 100, muted: true, decision: .audible) == (1, true))
        #expect(AudioOutput.rendererSettings(volume: 0, muted: false, decision: .audible).gain == 0)
        let silent = AudioOutput.rendererSettings(volume: 100, muted: false, decision: .silent)
        #expect(silent.gain == 0)
        #expect(silent.muted)
    }

    @Test func rendererEventsBecomeFlushSuggestions() {
        let changed = AudioOutput.event(for: AVSampleBufferAudioRenderer.Receiver.RenderingEvent.outputConfigurationChanged)
        #expect(changed == .flushSuggested(.outputConfigurationChanged))
        let flushed = AudioOutput.event(for: AVSampleBufferAudioRenderer.Receiver.SuggestedFlushReason.wasFlushedAutomatically(at: CMTime(value: 3, timescale: 2)))
        #expect(flushed == .flushSuggested(.flushedAutomatically(at: .seconds(1.5))))
        let reason = AudioOutput.event(for: AVSampleBufferAudioRenderer.Receiver.SuggestedFlushReason.outputConfigurationChanged)
        #expect(reason == .flushSuggested(.outputConfigurationChanged))
    }
}
