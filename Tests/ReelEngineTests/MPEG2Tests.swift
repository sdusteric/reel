import Foundation
import ReelCore
import Testing
@testable import ReelEngine

/// MPEG-2 in program streams (DVD .vob, .mpg) and transport streams (fixtures.sh, mpeg2/).
/// Their A/V sync is the av-sync gate of check.sh.
@Suite(.serialized) struct MPEG2Tests {
    @Test(arguments: [
        ("mpeg2/sync_mpeg2_mp2.mpg", "mp2"), ("mpeg2/sync_mpeg2_ac3.vob", "ac3"), ("mpeg2/ramp_mpeg2.ts", "mp2"),
    ])
    func opensWithTheSoftwareDecoderAndItsAudio(_ file: String, _ audio: String) async throws {
        let engine = TestEngines.make()
        let info = try await engine.open(fixtureURL(file))
        #expect(info.videoStream?.codec == "mpeg2video")
        #expect(info.videoDecoder == .software)
        #expect(info.audioStream?.codec == audio)
        #expect(await engine.lastReport?.landedPTS != nil, "the first frame is shown")
        await engine.close()
    }

    @Test func aSeekLandsAndPlaybackStaysInOrder() async throws {
        try await DecodeOrderTimestampTests.seekAndPlay("mpeg2/ramp_mpeg2.ts")
    }
}
