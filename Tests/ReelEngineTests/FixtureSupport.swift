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
        try fixtureURL(rawValue, sourceLocation: sourceLocation)
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

/// A file under the fixture directory by its relative path. Records a failure naming the fix
/// when it is missing.
func fixtureURL(_ relativePath: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
    let url = Fixture.directory.appending(path: relativePath)
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
        Issue.record(
            "Missing fixture \(relativePath) in \(Fixture.directory.path(percentEncoded: false)): run scripts/fixtures.sh",
            sourceLocation: sourceLocation
        )
        throw FixtureMissing(name: relativePath)
    }
    return url
}

// MARK: M3 fixtures (design sections 7.7, 7.8, 7.10 and 14)

/// The HDR and SDR patch ramps and the Dolby Vision files in hdr/.
enum HDRFixture: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case pqHEVCMKV = "hdr/pq_ramp_hevc.mkv"
    case pqHEVCMP4 = "hdr/pq_ramp_hevc.mp4"
    case hlgHEVCMKV = "hdr/hlg_ramp_hevc.mkv"
    case hlgHEVCMP4 = "hdr/hlg_ramp_hevc.mp4"
    case pqAV1 = "hdr/pq_ramp_av1.mkv"
    case pqVP9 = "hdr/pq_ramp_vp9.webm"
    case sdrH264 = "hdr/sdr_ramp_h264.mp4"
    case dv81MP4 = "hdr/dv81.mp4"
    case dv81MKV = "hdr/dv81.mkv"
    case dv84MP4 = "hdr/dv84.mp4"
    case dv5MP4 = "hdr/dv5.mp4"
    /// Real RPUs on every frame (make-dovi-rpu.c): profile 8.1, 8.4 and 5, level 3.
    case dv81RPU = "hdr/dv81_rpu.mp4"
    case dv84RPU = "hdr/dv84_rpu.mp4"
    case dv5RPU = "hdr/dv5_rpu.mp4"

    var testDescription: String { rawValue }

    func url(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        try fixtureURL(rawValue, sourceLocation: sourceLocation)
    }

    /// The ramp in logs/ramps.json that the pixels come from.
    var ramp: RampSet.Transfer {
        switch self {
        case .pqHEVCMKV, .pqHEVCMP4, .pqAV1, .pqVP9, .dv81MP4, .dv81MKV, .dv5MP4, .dv81RPU, .dv5RPU: .pq
        case .hlgHEVCMKV, .hlgHEVCMP4, .dv84MP4, .dv84RPU: .hlg
        case .sdrH264: .sdr
        }
    }

    var videoCodec: String {
        switch self {
        case .pqAV1: "av1"
        case .pqVP9: "vp9"
        case .sdrH264: "h264"
        default: "hevc"
        }
    }

    /// The Dolby Vision record make-dovi.py or make-dovi-rpu.c wrote: (profile, compatibility id).
    var dolbyVision: (profile: Int, compatibility: Int)? {
        switch self {
        case .dv81MP4, .dv81MKV, .dv81RPU: (8, 1)
        case .dv84MP4, .dv84RPU: (8, 4)
        case .dv5MP4, .dv5RPU: (5, 0)
        default: nil
        }
    }

    /// Codes are exact for lossless encodes; AV1 is lossy (4), the SDR H.264 near lossless (2).
    var codeTolerance: Int {
        switch self {
        case .pqAV1: 4
        case .sdrH264: 2
        default: 0
        }
    }

    static let frameCount = 48
}

/// logs/ramps.json from scripts/make-ramp.py: patch rectangles and expected limited-range codes.
struct RampSet: Decodable {
    enum Transfer: String, Sendable, CaseIterable {
        case pq, hlg, sdr
    }

    struct Patch: Decodable, Sendable {
        struct Rect: Decodable, Sendable { var x, y, w, h: Int }
        struct Codes: Decodable, Sendable { var y, cb, cr: Int }
        var name: String
        /// "neutral" or "primary".
        var kind: String
        var nits: Double?
        var signal: Double?
        var rect: Rect
        var codes: Codes

        var center: (x: Int, y: Int) { (rect.x + rect.w / 2, rect.y + rect.h / 2) }
    }

    struct Ramp: Decodable, Sendable {
        var width: Int
        var height: Int
        var bitDepth: Int
        var matrix: String
        var patches: [Patch]
    }

    var pq: Ramp
    var hlg: Ramp
    var sdr: Ramp

    subscript(transfer: Transfer) -> Ramp {
        switch transfer {
        case .pq: pq
        case .hlg: hlg
        case .sdr: sdr
        }
    }

    static func load(sourceLocation: SourceLocation = #_sourceLocation) throws -> RampSet {
        try JSONDecoder().decode(RampSet.self, from: Data(contentsOf: fixtureURL("logs/ramps.json", sourceLocation: sourceLocation)))
    }
}

/// Unusual but valid files, and three files that are not media, in odd/ (section 7.10).
enum OddFixture: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case zero = "odd/zero.mkv"
    case text = "odd/text.mp4"
    case random = "odd/random.mkv"
    case prores = "odd/prores.mov"
    case audioCover = "odd/audio_cover.mp3"
    case videoOnly = "odd/video_only.mp4"
    case oneFrame = "odd/one_frame.mkv"
    case tiny = "odd/tiny_16x16.mp4"
    case oddDimensions = "odd/odd_1921x1081.mkv"
    case resolutionChange = "odd/res_change.ts"
    case layoutChange = "odd/layout_change.ts"
    case timestampWrap = "odd/ts_wrap.ts"
    case variableFrameRate = "odd/vfr.mkv"
    case intraRefresh = "odd/intra_refresh.mp4"
    case h264422 = "odd/h264_422_10bit.mkv"
    case h264444 = "odd/h264_444.mkv"
    case editList = "odd/edit_list_offset.mp4"
    case manyTracks = "odd/many_tracks.mkv"
    /// 240 characters of CJK and emoji (250 UTF-16 units; APFS allows 255).
    case longName

    static let longFileName = String(String(repeating: "北線終點站的長夜與清晨", count: 30).prefix(226))
        + String(repeating: "🚇🌃", count: 5) + ".mkv"

    var path: String {
        self == .longName ? "odd/" + OddFixture.longFileName : rawValue
    }

    var testDescription: String { self == .longName ? "odd/<240-character name>.mkv" : rawValue }

    func url(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        try fixtureURL(path, sourceLocation: sourceLocation)
    }

    /// The `MediaProblem` kind opening must report; nil for files that play.
    var expectedProblem: String? {
        switch self {
        case .zero, .text, .random: "notMedia"
        case .prores: "unsupportedCodec"
        default: nil
        }
    }
}

/// corpus/: seeded damaged copies of eight base files and their manifest (scripts/make-corpus.py).
struct CorpusManifest: Decodable {
    struct Damage: Decodable, Sendable {
        var start: Int
        var end: Int
        var video: Bool
        var audio: Bool
    }

    struct Entry: Decodable, Sendable {
        var file: String
        var base: String
        var mutation: String
        /// "played", "classified" or "any".
        var expected: String
        var family: String
        var baseDuration: Double
        var dataEnd: Double?
        var damage: Damage?
    }

    var version: Int
    var files: [Entry]

    static let bases = [
        "h264_moov_end.mp4", "h264_faststart.mp4", "hevc.mkv", "av1.mkv", "vp9.webm", "h264.ts", "mpeg4.avi", "flv1.flv",
    ]

    static func load(sourceLocation: SourceLocation = #_sourceLocation) throws -> CorpusManifest {
        try JSONDecoder().decode(CorpusManifest.self, from: Data(contentsOf: fixtureURL("corpus/manifest.json", sourceLocation: sourceLocation)))
    }

    func url(_ entry: Entry) -> URL {
        Fixture.directory.appending(path: "corpus/\(entry.file)")
    }
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
