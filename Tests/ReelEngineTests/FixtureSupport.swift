import Foundation
import ReelCore
import Testing
@testable import ReelEngine

/// Generated test media from scripts/fixtures.sh (design section 14). Tests never read anything else.
enum Fixture: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case hevc10 = "hevc10_1080p24.mkv"
    case av1 = "av1_2160p60.mkv"
    case h264 = "h264_1080p30.mp4"
    case vp9 = "vp9_2160p60.webm"
    case syncH264 = "sync_h264_aac.mp4"
    case syncHEVC = "sync_hevc_opus.mkv"
    case hdr10 = "hdr10_hevc.mkv"
    case rot90 = "rot90_h264.mov"
    case annexB = "annexb_h264.ts"
    case mpeg4 = "mpeg4.avi"
    case flv1 = "flv1.flv"
    case nocues = "nocues_hevc.mkv"

    var testDescription: String { rawValue }

    static let directory: URL = {
        let environment = ReelEnvironment()
        // Tests/ReelEngineTests/FixtureSupport.swift -> repo root.
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return environment.fixturesDirectory(repoRoot: repoRoot) ?? repoRoot.appending(path: "build/fixtures")
    }()

    /// The fixture's URL. Records a failure naming the fix when the file is missing.
    func url(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let url = Fixture.directory.appending(path: rawValue)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            Issue.record("Missing fixture \(rawValue) in \(Fixture.directory.path(percentEncoded: false)): run scripts/fixtures.sh", sourceLocation: sourceLocation)
            throw FixtureMissing(name: rawValue)
        }
        return url
    }

    /// Presentation time of the first video frame (mpegts starts at 1.4 s, the others at 0).
    func videoStart() throws -> MediaTime {
        let source = try MediaSource(url: url())
        while let packet = try source.readPacket() {
            if packet.streamIndex == source.videoStreamIndex, packet.isKeyframe, let pts = packet.pts { return pts }
        }
        return .zero
    }

    /// Codec of the video stream, as FFmpeg names it.
    var videoCodec: String {
        switch self {
        case .hevc10, .syncHEVC, .hdr10, .nocues: "hevc"
        case .av1: "av1"
        case .h264, .syncH264, .rot90, .annexB: "h264"
        case .vp9: "vp9"
        case .mpeg4: "mpeg4"
        case .flv1: "flv1"
        }
    }

    var codec: VideoCodec {
        switch videoCodec {
        case "hevc": .hevc
        case "h264": .h264
        case "av1": .av1
        case "vp9": .vp9
        default: .other
        }
    }

    var size: (width: Int, height: Int) {
        switch self {
        case .hevc10, .h264, .hdr10, .nocues: (1920, 1080)
        case .av1, .vp9: (3840, 2160)
        case .syncH264, .syncHEVC, .rot90, .annexB: (1280, 720)
        case .mpeg4: (640, 480)
        case .flv1: (320, 240)
        }
    }

    var frameRate: Double {
        switch self {
        case .hevc10, .hdr10, .nocues, .syncHEVC: 24
        case .av1, .vp9: 60
        case .h264, .syncH264, .rot90, .annexB: 30
        case .mpeg4, .flv1: 25
        }
    }

    /// Codecs VideoToolbox decodes on this Mac.
    static let hardwareFixtures: [Fixture] = [.hevc10, .av1, .h264, .vp9, .hdr10, .rot90, .annexB, .nocues, .syncH264, .syncHEVC]
    static let softwareOnlyFixtures: [Fixture] = [.mpeg4, .flv1]
}

struct FixtureMissing: Error, CustomStringConvertible {
    let name: String
    var description: String { "fixture \(name) is missing: run scripts/fixtures.sh" }
}

extension Demuxer {
    /// Polls until `condition` holds or `timeout` passes.
    func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// Polls `condition` every millisecond on a dedicated dispatch queue and returns the instant it
/// first held (nil after `timeout`). Unlike a sleeping task, the poll does not wait for a free
/// thread of the cooperative pool, so a busy test process does not inflate the measured latency.
func instantWhen(timeout: Duration = .seconds(10), _ condition: @escaping @Sendable () -> Bool) async -> ContinuousClock.Instant? {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "reel.tests.poll", qos: .userInitiated).async {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if condition() {
                    continuation.resume(returning: ContinuousClock.now)
                    return
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            continuation.resume(returning: nil)
        }
    }
}
