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

    @Test(arguments: ["mpeg2/ramp_mpeg2.ts", "mpeg2/ramp_mpeg2.mpg", "mpeg2/ramp_mpeg2.m2v"])
    func aSeekLandsAndPlaybackStaysInOrder(_ file: String) async throws {
        try await DecodeOrderTimestampTests.seekAndPlay(file)
    }

    /// Just before a keyframe: the frame shown there is the last of the GOP before. A program
    /// stream seek used to wait forever there, starting at a "keyframe" from FFmpeg's index that
    /// was a B-picture.
    @Test(arguments: ["mpeg2/ramp_mpeg2.ts", "mpeg2/ramp_mpeg2.mpg", "mpeg2/ramp_mpeg2.m2v"])
    func aSeekJustBeforeAKeyframeLands(_ file: String) async throws {
        let source = try MediaSource(url: fixtureURL(file))
        var keyframes: [MediaTime] = []
        while keyframes.count < 3, let packet = try source.readPacket() {
            if packet.streamIndex == source.videoStreamIndex, packet.isKeyframe, let pts = packet.pts { keyframes.append(pts) }
        }
        let third = try #require(keyframes.count == 3 ? keyframes[2] : nil, "keyframes \(keyframes)")
        try await DecodeOrderTimestampTests.seekAndPlay(file, target: third - .milliseconds(20))
    }
}
