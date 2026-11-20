import CoreVideo
import Foundation
import ReelCore
import Synchronization
import Testing
@testable import ReelEngine

/// Interlaced frames are deinterlaced before they are shown; progressive ones are left alone.
/// The fixtures weave two fields of a moving picture into each frame (fixtures.sh, interlaced/).
@Suite(.serialized) struct DeinterlaceTests {
    /// Share of luma samples that stick out from both lines around them by more than 8% in the
    /// same direction while those lines agree: the comb pattern of two fields from different
    /// instants. A progressive picture has almost none.
    static func combShare(_ buffer: CVReadOnlyPixelBuffer) -> Double {
        guard let plane = FrameGrabber.lumaPlane(buffer) else { return 1 }
        let (width, height, values) = (plane.width, plane.height, plane.values)
        var combed = 0
        var counted = 0
        for row in 1..<(height - 1) {
            for column in 0..<width {
                let above = values[(row - 1) * width + column]
                let own = values[row * width + column]
                let below = values[(row + 1) * width + column]
                counted += 1
                if (own - above) * (own - below) > 0.08 * 0.08, abs(above - below) < 0.08 { combed += 1 }
            }
        }
        return Double(combed) / Double(max(counted, 1))
    }

    /// Frames the engine shows while playing about one second.
    private static func shownFrames(_ file: String, force: VideoDecoderKind? = nil) async throws -> (info: MediaInfo, frames: [DecodedFrame]) {
        let engine = TestEngines.make(force: force)
        let frames = Mutex<[DecodedFrame]>([])
        await engine.setFrameObserver { frame in frames.withLock { if $0.count < 30 { $0.append(frame) } } }
        let info = try await engine.open(fixtureURL(file))
        await engine.play()
        let deadline = ContinuousClock.now + .seconds(10)
        while frames.withLock({ $0.count }) < 30, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await engine.close()
        return (info, frames.withLock { $0 })
    }

    @Test(arguments: [
        ("interlaced/mpeg2_tff.ts", VideoDecoderKind.software), ("interlaced/h264_mbaff_tff.ts", .hardware),
        ("interlaced/h264_mbaff_tff.ts", .software),
    ])
    func interlacedFramesAreShownWithoutCombing(_ file: String, _ decoder: VideoDecoderKind) async throws {
        let (info, frames) = try await Self.shownFrames(file, force: decoder)
        #expect(info.videoDecoder == decoder)
        #expect(frames.count >= 20)
        let shown = frames.map { Self.combShare($0.pixelBuffer) }
        // The same frames straight from the decoder, before the deinterlacer.
        let raw = try FrameGrabber.grab(url: fixtureURL(file), at: frames[10].time, decoder: decoder).frame
        let before = Self.combShare(raw.pixelBuffer)
        let after = shown.sorted()[shown.count / 2]
        #expect(before > 0.01, "the fixture is combed: \(before)")
        #expect(after < before / 10, "combing \(before) before, \(after) shown (median)")
        #expect(frames.allSatisfy { Deinterlacer.fieldOrder(of: $0, stream: .progressive) == .progressive })
    }

    @Test func progressiveFramesPassUntouched() async throws {
        let (_, frames) = try await Self.shownFrames(Fixture.h264.rawValue)
        #expect(frames.count >= 20)
        #expect(frames.allSatisfy { Deinterlacer.fieldOrder(of: $0, stream: .progressive) == .progressive })
        let first = try #require(frames.first)
        let processed = try #require(Deinterlacer.shared).process(first, stream: .progressive)
        #expect(processed.pixelBuffer.withUnsafeBuffer { a in first.pixelBuffer.withUnsafeBuffer { b in a === b } })
    }
}
