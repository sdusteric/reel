import Foundation
import Testing
@testable import ReelCore

@Suite struct MediaProblemTests {
    struct CopyRow: Sendable, CustomTestStringConvertible {
        var problem: MediaProblem
        var title: String
        var explanation: String
        var buttons: [String]

        var testDescription: String { problem.kind }
    }

    /// The section 9.14 copy table, word for word.
    static let copy: [CopyRow] = [
        CopyRow(
            problem: .cutShort,
            title: "This file can't be played",
            explanation: "The file ends before its first video frame. It may still be downloading, or the copy was cut short.",
            buttons: ["Show in Finder", "Open Another File\u{2026}"]
        ),
        CopyRow(
            problem: .notMedia,
            title: "This file can't be played",
            explanation: "Reel doesn't recognize this as a video or audio file.",
            buttons: ["Show in Finder", "Open Another File\u{2026}"]
        ),
        CopyRow(
            problem: .noPlayableStream,
            title: "This file can't be played",
            explanation: "The file has no video or audio that Reel can play.",
            buttons: ["Show in Finder", "Open Another File\u{2026}"]
        ),
        CopyRow(
            problem: .unsupportedCodec("ProRes"),
            title: "This file can't be played",
            explanation: "The video uses ProRes, which Reel can't decode.",
            buttons: ["Show in Finder", "Open Another File\u{2026}"]
        ),
        CopyRow(
            problem: .unreadable("Input/output error"),
            title: "This file couldn't be read",
            explanation: "macOS reported a read error. The disk may have a problem, or Reel may not have access to this folder.",
            buttons: ["Try Again", "Open Another File\u{2026}"]
        ),
        CopyRow(
            problem: .volumeGone("Eric X9 Pro"),
            title: "\u{201C}Eric X9 Pro\u{201D} was disconnected",
            explanation: "Reel saved your place and will continue when the drive is connected again.",
            buttons: ["Close File", "Try Again"]
        ),
    ]

    @Test(arguments: copy)
    func copyMatchesTheDesign(_ row: CopyRow) {
        #expect(row.problem.title == row.title)
        #expect(row.problem.explanation == row.explanation)
        #expect(row.problem.buttons.map(\.title) == row.buttons)
        #expect(row.problem.primaryButton.title == row.buttons.last)
        #expect(!row.problem.title.isEmpty && !row.problem.explanation.isEmpty)
    }

    @Test func driveGoneNamesTheSavedTime() {
        #expect(MediaProblem.volumeGone("Eric X9 Pro").explanation(savedPosition: "31:04")
            == "Reel saved your place at 31:04 and will continue when the drive is connected again.")
        #expect(MediaProblem.notMedia.explanation(savedPosition: "31:04") == MediaProblem.notMedia.explanation)
    }

    @Test func glyphsAndKinds() {
        #expect(MediaProblem.volumeGone("X").symbolName == "externaldrive")
        #expect(MediaProblem.cutShort.symbolName == "doc" && MediaProblem.cutShort.showsExclamation)
        #expect(!MediaProblem.volumeGone("X").showsExclamation)
        #expect(Self.copy.map(\.problem.kind) == ["cutShort", "notMedia", "noPlayableStream", "unsupportedCodec", "unreadable", "volumeGone"])
    }

    // MARK: Classification

    @Test func engineErrorsMapToProblems() {
        let path = "/Users/someone/Videos/a.mkv"
        let cases: [(EngineError, MediaProblem)] = [
            (.notMedia("Invalid data found when processing input"), .notMedia),
            (.cutShort("End of file"), .cutShort),
            (.noPlayableStream, .noPlayableStream),
            (.unsupportedCodec("prores"), .unsupportedCodec("ProRes")),
            (.unsupportedCodec("hevc without parameter sets"), .unsupportedCodec("HEVC")),
            (.io("Input/output error"), .unreadable("Input/output error")),
            (.openFailed("avformat_open_input: Invalid data found when processing input"), .notMedia),
            (.openFailed("avformat_find_stream_info: End of file"), .cutShort),
            (.openFailed("avformat_open_input: Permission denied"), .unreadable("avformat_open_input: Permission denied")),
            (.openFailed("avformat_open_input: No such file or directory"), .unreadable("avformat_open_input: No such file or directory")),
            (.openFailed("timed out"), .unreadable("timed out")),
            (.openFailed("something new"), .notMedia),
            (.decoderFailed("boom"), .unreadable("boom")),
        ]
        for (error, expected) in cases {
            #expect(MediaProblem.classify(from: error, path: path, mountedVolumes: []) == expected, "\(error)")
        }
    }

    @Test func aMissingVolumeWinsOverTheError() {
        let path = "/Volumes/Eric X9 Pro/Shows/Northern.Line.S01E01.mkv"
        #expect(MediaProblem.classify(from: .io("Device not configured"), path: path, mountedVolumes: []) == .volumeGone("Eric X9 Pro"))
        #expect(MediaProblem.classify(from: .openFailed("No such file or directory"), path: path, mountedVolumes: ["Other"]) == .volumeGone("Eric X9 Pro"))
        #expect(MediaProblem.classify(from: .io("Device not configured"), path: path, mountedVolumes: ["Eric X9 Pro"])
            == .unreadable("Device not configured"))
    }

    @Test func volumeNamesComeOnlyFromVolumesPaths() {
        #expect(MediaProblem.volumeName(of: "/Volumes/Disk/a.mkv") == "Disk")
        #expect(MediaProblem.volumeName(of: "/Volumes/Disk/Shows/a.mkv") == "Disk")
        #expect(MediaProblem.volumeName(of: "/Volumes/Disk") == nil)
        #expect(MediaProblem.volumeName(of: "/Users/someone/Volumes/Disk/a.mkv") == nil)
        #expect(MediaProblem.volumeName(of: "relative/a.mkv") == nil)
    }

    @Test func codecDisplayNames() {
        #expect(MediaProblem.displayCodecName("prores") == "ProRes")
        #expect(MediaProblem.displayCodecName("vc1") == "VC-1")
        #expect(MediaProblem.displayCodecName("weirdcodec") == "weirdcodec")
    }

    @Test func problemsRoundTripThroughJSON() throws {
        for row in Self.copy {
            let data = try JSONEncoder().encode(row.problem)
            #expect(try JSONDecoder().decode(MediaProblem.self, from: data) == row.problem)
        }
        let text = String(decoding: try JSONEncoder().encode(MediaProblem.unsupportedCodec("ProRes")), as: UTF8.self)
        #expect(text.contains(#""kind":"unsupportedCodec""#))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MediaProblem.self, from: Data(#"{"kind":"gremlins"}"#.utf8)) }
    }

    @Test func newEngineErrorsDescribeThemselves() {
        #expect(EngineError.notMedia("x").errorDescription?.isEmpty == false)
        #expect(EngineError.cutShort("x").errorDescription?.isEmpty == false)
    }
}
