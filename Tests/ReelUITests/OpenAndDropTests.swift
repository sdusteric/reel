import Foundation
import Testing
@testable import ReelUI

@Suite struct OpenAndDropTests {
    private func file(_ name: String) -> URL {
        URL(filePath: "/media/\(name)", directoryHint: .notDirectory)
    }

    @Test(arguments: [
        "a.mp4", "a.m4v", "a.mov", "a.mkv", "a.webm", "a.flv", "a.avi", "a.ts", "a.m2ts", "a.mts", "a.mpg", "a.mpeg", "a.vob", "a.m2v",
        "a.ogv", "a.ogg", "a.wav", "a.mp3", "a.aac", "a.flac", "UPPER.MKV", "Mixed.Mp4", "show.s01e01.en.mkv",
    ])
    func acceptsSupportedExtensions(_ name: String) {
        #expect(SupportedMedia.isSupported(file(name)))
    }

    @Test(arguments: ["a.txt", "a.srt", "a.ass", "a.jpg", "a.pdf", "a.mkv.part", "noextension", "a.zip", ".mkv"])
    func rejectsOtherFiles(_ name: String) {
        #expect(!SupportedMedia.isSupported(file(name)))
    }

    @Test func rejectsDirectoriesAndRemoteURLs() throws {
        #expect(!SupportedMedia.isSupported(URL(filePath: "/media/Season.mkv", directoryHint: .isDirectory)))
        let remote = try #require(URL(string: "https://example.com/a.mp4"))
        #expect(!SupportedMedia.isSupported(remote))
    }

    @Test func aDropOpensTheFirstPlayableFile() {
        let urls = [file("notes.txt"), file("cover.jpg"), file("ep2.mkv"), file("ep3.mkv")]
        #expect(SupportedMedia.firstPlayable(in: urls) == file("ep2.mkv"))
        #expect(SupportedMedia.firstPlayable(in: [file("notes.txt")]) == nil)
        #expect(SupportedMedia.firstPlayable(in: []) == nil)
    }

    @Test func launchWithAFileArgumentOpensIt() {
        let cwd = URL(filePath: "/work", directoryHint: .isDirectory)
        #expect(LaunchRequest.parse([], currentDirectory: cwd) == .app(file: nil))
        #expect(LaunchRequest.parse(["/m/a.mkv"], currentDirectory: cwd) == .app(file: URL(filePath: "/m/a.mkv")))
        #expect(LaunchRequest.parse(["clips/b.mp4"], currentDirectory: cwd) == .app(file: URL(filePath: "/work/clips/b.mp4")))
        #expect(
            LaunchRequest.parse(["-NSDocumentRevisionsDebugMode", "YES", "/m/a.mkv"], currentDirectory: cwd)
                == .app(file: URL(filePath: "/m/a.mkv"))
        )
        #expect(LaunchRequest.parse(["-psn_0_12345"], currentDirectory: cwd) == .app(file: nil))
    }

    @Test func shotArgumentsParse() {
        let cwd = URL(filePath: "/work", directoryHint: .isDirectory)
        let request = LaunchRequest.parse(
            ["--shot", "paused-osd", "--appearance", "dark", "--size", "1280x720", "--out", "shots/p.png",
             "--fixture", "/f/h264.mp4", "--at", "7.5"],
            currentDirectory: cwd
        )
        let expected = ShotOptions(
            scenario: .pausedOSD,
            appearance: .dark,
            size: CGSize(width: 1280, height: 720),
            output: URL(filePath: "/work/shots/p.png"),
            fixture: URL(filePath: "/f/h264.mp4"),
            at: 7.5
        )
        #expect(request == .shot(expected))
    }

    @Test(arguments: [
        ["--shot", "sideways", "--out", "/o.png"],
        ["--shot", "empty"],
        ["--shot", "empty", "--out", "/o.png", "--size", "big"],
        ["--shot", "empty", "--out", "/o.png", "--appearance", "sepia"],
        ["--shot", "empty", "--out", "/o.png", "--bogus", "1"],
        ["--shot", "empty", "--out"],
    ])
    func badShotArgumentsAreRejected(_ arguments: [String]) {
        let request = LaunchRequest.parse(arguments, currentDirectory: URL(filePath: "/"))
        guard case .invalid = request else {
            Issue.record("expected invalid, got \(request)")
            return
        }
    }

    @Test func windowSizingFitsTheFirstVideoAndKeepsTheCentreLater() {
        let visible = CGRect(x: 0, y: 0, width: 3440, height: 1415)
        let first = WindowSizing.firstOpenFrame(videoSize: CGSize(width: 1920, height: 1080), visible: visible)
        #expect(first.size == CGSize(width: 1920, height: 1080), "1080p fits 80% of a 3440x1440 screen at 1x")
        #expect(abs(first.midX - visible.midX) <= 1)

        let small = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let fitted = WindowSizing.firstOpenFrame(videoSize: CGSize(width: 3840, height: 2160), visible: small)
        #expect(fitted.width <= 1512 * 0.8 + 1)
        #expect(fitted.height <= 945 * 0.8 + 1)

        let later = WindowSizing.laterOpenFrame(
            videoSize: CGSize(width: 1080, height: 1920),
            current: CGRect(x: 100, y: 100, width: 800, height: 450),
            visible: visible
        )
        #expect(later.height <= visible.height)
        #expect(abs(later.midX - 500) <= 1)
        let wide = WindowSizing.laterOpenFrame(
            videoSize: CGSize(width: 2560, height: 1080),
            current: CGRect(x: 100, y: 100, width: 800, height: 450),
            visible: visible
        )
        #expect(wide.width == 800)
        #expect(wide.height == 338)
    }

    /// The window scale keys (design 9.1): half, double and fit to screen keep the window's centre
    /// and keep it on the visible frame. Pure geometry, so no window is created.
    @Test func windowScaleKeysResizeAroundTheCentreAndStayOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 3440, height: 1415)
        let video = CGSize(width: 1920, height: 1080)
        let current = CGRect(x: 520, y: 330, width: 960, height: 540)

        let half = WindowSizing.scaledFrame(videoSize: video, scale: .factor(0.5), current: current, visible: visible)
        #expect(half == CGRect(x: 520, y: 330, width: 960, height: 540))

        let double = WindowSizing.scaledFrame(videoSize: video, scale: .factor(2), current: current, visible: visible)
        #expect(double.size == CGSize(width: 2516, height: 1415), "2x of 1080p is fitted to the visible frame")
        #expect(visible.contains(double))

        let small = CGSize(width: 640, height: 360)
        let fitted = WindowSizing.scaledFrame(videoSize: small, scale: .fitScreen, current: current, visible: visible)
        #expect(fitted.size == CGSize(width: 2516, height: 1415), "fit to screen grows a small video")
        #expect(visible.contains(fitted))

        let nearCorner = CGRect(x: 3300, y: 0, width: 100, height: 100)
        let actual = WindowSizing.scaledFrame(videoSize: video, scale: .factor(1), current: nearCorner, visible: visible)
        #expect(actual == CGRect(x: 1520, y: 0, width: 1920, height: 1080), "clamped to the visible frame")
    }
}
