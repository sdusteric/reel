import Foundation
import Testing
@testable import ReelCore

@Suite struct ExternalSubtitlesTests {
    private let video = URL(filePath: "/media/Show/Movie.mkv")

    private func files(_ names: [String]) -> [URL] {
        names.map { URL(filePath: "/media/Show/\($0)") }
    }

    private func names(_ found: [ExternalSubtitle]) -> [String] {
        found.map(\.url.lastPathComponent)
    }

    @Test func matchesByStemCaseInsensitivelyWithExactOrDotPrefix() {
        let found = ExternalSubtitles.discover(for: video, candidates: files([
            "movie.srt", "Movie.en.srt", "MOVIE.zh-Hans.ass", "Movie2.srt", "Moviex.en.srt", "Other.srt", "Movie.mkv",
        ]))
        #expect(names(found) == ["Movie.en.srt", "movie.srt", "MOVIE.zh-Hans.ass"])
    }

    @Test func parsesLanguagesAndFansubTags() {
        let found = ExternalSubtitles.discover(for: video, candidates: files([
            "Movie.chs.ass", "Movie.cht&eng.ass", "Movie.sc.srt", "Movie.tc.srt", "Movie.big5.srt", "Movie.gb.srt",
            "Movie.zh-TW.srt", "Movie.jpn.srt",
        ]))
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0) })
        #expect(byName["Movie.chs.ass"]?.track.chineseScript == .simplified)
        #expect(byName["Movie.cht&eng.ass"]?.track.chineseScript == .traditional)
        #expect(byName["Movie.cht&eng.ass"]?.extraLanguages == ["eng"])
        #expect(byName["Movie.sc.srt"]?.track.chineseScript == .simplified)
        #expect(byName["Movie.tc.srt"]?.track.chineseScript == .traditional)
        #expect(byName["Movie.big5.srt"]?.track.chineseScript == .traditional)
        #expect(byName["Movie.gb.srt"]?.track.chineseScript == .simplified)
        #expect(byName["Movie.zh-TW.srt"]?.track.label().title == "Chinese (Traditional)")
        #expect(byName["Movie.jpn.srt"]?.track.label().title == "Japanese")
        #expect(byName["Movie.chs.ass"]?.format == .ass)
    }

    @Test func parsesFlags() throws {
        let found = ExternalSubtitles.discover(for: video, candidates: files([
            "Movie.EN.forced.srt", "Movie.en.sdh.srt", "Movie.en.hi.srt", "Movie.hi.srt", "Movie.en.default.srt",
        ]))
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0) })
        let forced = try #require(byName["Movie.EN.forced.srt"])
        #expect(forced.isForced)
        #expect(forced.language == "EN")
        #expect(byName["Movie.en.sdh.srt"]?.isHearingImpaired == true)
        #expect(byName["Movie.en.hi.srt"]?.isHearingImpaired == true)
        #expect(byName["Movie.en.hi.srt"]?.language == "en")
        // Alone, "hi" is Hindi.
        #expect(byName["Movie.hi.srt"]?.language == "hi")
        #expect(byName["Movie.hi.srt"]?.isHearingImpaired == false)
        #expect(byName["Movie.en.default.srt"]?.isDefault == true)
        #expect(byName["Movie.en.sdh.srt"]?.track.label().title == "English SDH")
    }

    @Test func searchesSubsAndSubtitlesFolders() {
        let candidates = [
            URL(filePath: "/media/Show/Movie.en.srt"),
            URL(filePath: "/media/Show/Subs/Movie.zh.srt"),
            URL(filePath: "/media/Show/Subtitles/Movie.ja.vtt"),
            URL(filePath: "/media/Show/Extras/Movie.fr.srt"),
            URL(filePath: "/media/Show/Subs/Deeper/Movie.de.srt"),
            URL(filePath: "/media/Other/Movie.es.srt"),
        ]
        let found = ExternalSubtitles.discover(for: video, candidates: candidates)
        #expect(names(found) == ["Movie.en.srt", "Movie.ja.vtt", "Movie.zh.srt"])
        let folders = ExternalSubtitles.searchFolders(for: video).map(\.lastPathComponent)
        #expect(folders.contains("Subs"))
        #expect(folders.contains("Subtitles"))
    }

    @Test func supportsSrtAssSsaAndVttOnly() {
        let found = ExternalSubtitles.discover(for: video, candidates: files([
            "Movie.srt", "Movie.ass", "Movie.ssa", "Movie.vtt", "Movie.txt", "Movie.nfo", "Movie.smi",
        ]))
        #expect(names(found) == ["Movie.ass", "Movie.srt", "Movie.ssa", "Movie.vtt"])
        #expect(found.allSatisfy { $0.isSupported })
    }

    @Test func vobSubAndSupAreListedAsUnsupportedWithAReason() throws {
        let found = ExternalSubtitles.discover(for: video, candidates: files([
            "Movie.idx", "Movie.sub", "Movie.en.sup", "Movie.fr.sub",
        ]))
        #expect(names(found) == ["Movie.en.sup", "Movie.idx"])
        let vobsub = try #require(found.first { $0.format == .vobsub })
        #expect(!vobsub.isSupported)
        #expect(vobsub.unsupportedReason?.isEmpty == false)
        let sup = try #require(found.first { $0.format == .sup })
        #expect(sup.unsupportedReason?.isEmpty == false)
        #expect(sup.track.label().tag == "PGS")
        let reason: String = sup.unsupportedReason ?? "missing"
        let detail: String = sup.track.label().detail ?? ""
        #expect(detail.contains(reason))
        #expect(!sup.track.isSupported)
    }

    @Test func hiddenAndAppleDoubleFilesAreIgnored() {
        let found = ExternalSubtitles.discover(for: video, candidates: files(["._Movie.srt", ".Movie.srt", "Movie.srt"]))
        #expect(names(found) == ["Movie.srt"])
    }

    @Test func scanListsRealFoldersInAScratchDirectory() throws {
        let scratch = try ScratchDirectory("reel-external")
        defer { scratch.remove() }
        let subs = scratch.url.appending(path: "Subs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        for name in ["Episode.mkv", "Episode.zh-Hans.srt", "notes.txt"] {
            try Data("x".utf8).write(to: scratch.file(name))
        }
        try Data("x".utf8).write(to: subs.appending(path: "Episode.en.ass"))
        let found = ExternalSubtitles.scan(for: scratch.file("Episode.mkv"))
        #expect(names(found) == ["Episode.zh-Hans.srt", "Episode.en.ass"])
    }

    @Test func fixtureSidecarIsSimplifiedChinese() throws {
        let fixture = URL(filePath: "/fixtures/subs_tracks.mkv")
        let found = ExternalSubtitles.discover(for: fixture, candidates: [
            URL(filePath: "/fixtures/subs_tracks.zh-Hans.srt"),
            URL(filePath: "/fixtures/subs_utf8.srt"),
            URL(filePath: "/fixtures/subs_tracks.mkv"),
        ])
        let sidecar = try #require(found.first)
        #expect(found.count == 1)
        #expect(sidecar.track.label().title == "Chinese (Simplified)")
        #expect(sidecar.track.isExternal)
    }
}
