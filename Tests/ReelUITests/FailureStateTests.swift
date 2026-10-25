import AppKit
import ReelCore
import Testing
@testable import ReelUI

@MainActor
@Suite struct FailureStateTests {
    private struct Row {
        var problem: MediaProblem
        var title: String
        var explanation: String
        var buttons: [String]
    }

    /// The table of design 9.14.
    private let table: [Row] = [
        Row(
            problem: .cutShort,
            title: "This file can't be played",
            explanation: "The file ends before its first video frame. It may still be downloading, or the copy was cut short.",
            buttons: ["Show in Finder", "Open Another File\u{2026}"]
        ),
        Row(
            problem: .notMedia,
            title: "This file can't be played",
            explanation: "Reel doesn't recognise this as a video or audio file.",
            buttons: ["Show in Finder", "Open Another File\u{2026}"]
        ),
        Row(
            problem: .noPlayableStream,
            title: "This file can't be played",
            explanation: "The file has no video or audio that Reel can play.",
            buttons: ["Show in Finder", "Open Another File\u{2026}"]
        ),
        Row(
            problem: .unsupportedCodec("ProRes"),
            title: "This file can't be played",
            explanation: "The video uses ProRes, which Reel can't decode.",
            buttons: ["Show in Finder", "Open Another File\u{2026}"]
        ),
        Row(
            problem: .unreadable("Input/output error"),
            title: "This file couldn't be read",
            explanation: "macOS reported a read error. The disk may have a problem, or Reel may not have access to this folder.",
            buttons: ["Try Again", "Open Another File\u{2026}"]
        ),
        Row(
            problem: .volumeGone("Eric X9 Pro"),
            title: "\u{201C}Eric X9 Pro\u{201D} was disconnected",
            explanation: "Reel saved your place at 31:04 and will continue when the drive is connected again.",
            buttons: ["Close File", "Try Again"]
        ),
    ]

    @Test func theCopyOfEachProblemIsTheTableOf914() {
        for row in table {
            let content = FailureCardContent(problem: row.problem, fileName: "a.mkv", detail: "detail", savedPosition: "31:04")
            #expect(content.title == row.title, "\(row.problem.kind)")
            #expect(content.explanation == row.explanation, "\(row.problem.kind)")
            #expect(content.buttons.map(\.title) == row.buttons, "\(row.problem.kind)")
        }
    }

    @Test func theFileNameShowsForFilesAndNotForDrives() {
        let file = FailureCardContent(problem: .notMedia, fileName: "a.mkv", detail: nil, savedPosition: nil)
        #expect(file.fileName == "a.mkv")
        let drive = FailureCardContent(problem: .volumeGone("X9"), fileName: "a.mkv", detail: nil, savedPosition: "00:10")
        #expect(drive.fileName == nil)
    }

    @Test func anEmptyDetailIsLeftOut() {
        #expect(FailureCardContent(problem: .cutShort, fileName: nil, detail: "", savedPosition: nil).detail == nil)
        let detail = "Matroska header found, then the file ends after 4 KB (FFmpeg: End of file)."
        #expect(FailureCardContent(problem: .cutShort, fileName: nil, detail: detail, savedPosition: nil).detail == detail)
    }

    @Test func thePrimaryButtonIsTheLastOne() {
        #expect(MediaProblem.cutShort.primaryButton == .openAnotherFile)
        #expect(MediaProblem.unreadable("x").primaryButton == .openAnotherFile)
        #expect(MediaProblem.volumeGone("X9").primaryButton == .tryAgain)
    }

    @Test func theGlyphsExistOnThisMac() {
        for row in table {
            let content = FailureCardContent(problem: row.problem, fileName: nil, detail: nil, savedPosition: nil)
            #expect(NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil) != nil, Comment(rawValue: content.symbol))
        }
        let drive = FailureCardContent(problem: .volumeGone("X9"), fileName: nil, detail: nil, savedPosition: nil)
        #expect(drive.symbol == "externaldrive" && !drive.showsExclamation)
        let file = FailureCardContent(problem: .cutShort, fileName: nil, detail: nil, savedPosition: nil)
        #expect(file.symbol == "doc" && file.showsExclamation)
        #expect(NSImage(systemSymbolName: "exclamationmark", accessibilityDescription: nil) != nil)
    }

    @Test func noCopyContainsADash() {
        for row in table {
            for text in [row.title, row.explanation] + row.buttons {
                #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"))
            }
        }
        #expect(!DolbyVisionPolicy.noteTitle.contains("\u{2014}"))
        #expect(!DolbyVisionPolicy.noteBody.contains("\u{2014}"))
    }
}
