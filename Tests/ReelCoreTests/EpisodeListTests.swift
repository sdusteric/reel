import Foundation
import Testing
@testable import ReelCore

@Suite struct EpisodeListTests {
    private let folder = URL(filePath: "/media/Northern Line", directoryHint: .isDirectory)

    private func url(_ name: String) -> URL {
        folder.appending(path: name, directoryHint: .notDirectory)
    }

    private func list(current: String, _ names: [String]) -> EpisodeList {
        EpisodeList(current: url(current), folderContents: names.map(url))
    }

    @Test func naturalSortOrdersEpisodeNumbers() {
        let episodes = list(current: "Northern.Line.S01E02.mkv", [
            "Northern.Line.S01E10.mkv", "Northern.Line.S01E02.mkv", "Northern.Line.S01E01.mkv", "Northern.Line.S01E03.mkv",
        ])
        #expect(episodes.files.map(\.lastPathComponent) == [
            "Northern.Line.S01E01.mkv", "Northern.Line.S01E02.mkv", "Northern.Line.S01E03.mkv", "Northern.Line.S01E10.mkv",
        ])
        #expect(episodes.currentIndex == 1)
        #expect(episodes.next?.lastPathComponent == "Northern.Line.S01E03.mkv")
        #expect(episodes.previous?.lastPathComponent == "Northern.Line.S01E01.mkv")
    }

    @Test func naturalSortHandlesChineseEpisodeNumbers() {
        let episodes = list(current: "第2集.mp4", ["第10集.mp4", "第2集.mp4", "第1集.mp4"])
        #expect(episodes.files.map(\.lastPathComponent) == ["第1集.mp4", "第2集.mp4", "第10集.mp4"])
    }

    @Test func junkFilesAreExcluded() {
        let episodes = list(current: "Show.E02.mkv", [
            "Show.E01.mkv", "Show.E02.mkv", "._Show.E02.mkv", ".hidden.mkv", "notes.txt", "Show.E02.srt", "cover.jpg",
            "Show.E03.MP4", "Show.E04.webm",
        ])
        #expect(episodes.files.map(\.lastPathComponent) == ["Show.E01.mkv", "Show.E02.mkv", "Show.E03.MP4", "Show.E04.webm"])
    }

    @Test func filesFromOtherFoldersAreIgnored() {
        let other = URL(filePath: "/media/Other/Show.E03.mkv")
        let episodes = EpisodeList(current: url("Show.E01.mkv"), folderContents: [url("Show.E01.mkv"), other])
        #expect(episodes.count == 1)
        #expect(episodes.isAlone)
    }

    @Test func nextAfterLastIsNil() {
        let episodes = list(current: "b.mkv", ["a.mkv", "b.mkv"])
        #expect(episodes.next == nil)
        #expect(episodes.previous?.lastPathComponent == "a.mkv")
        let first = list(current: "a.mkv", ["a.mkv", "b.mkv"])
        #expect(first.previous == nil)
        #expect(first.next?.lastPathComponent == "b.mkv")
    }

    @Test func aloneFileHasNoNeighbours() {
        let episodes = list(current: "movie.mkv", ["movie.mkv", "movie.srt"])
        #expect(episodes.isAlone)
        #expect(episodes.next == nil)
        #expect(episodes.previous == nil)
    }

    @Test func currentFileMissingFromTheListingIsStillIncluded() {
        let episodes = list(current: "b.mkv", ["a.mkv", "c.mkv"])
        #expect(episodes.files.map(\.lastPathComponent) == ["a.mkv", "b.mkv", "c.mkv"])
        #expect(episodes.currentIndex == 1)
    }

    @Test func followingListsTheFilesAfterTheCurrentOne() {
        let episodes = list(current: "a.mkv", ["a.mkv", "b.mkv", "c.mkv", "d.mkv", "e.mkv"])
        #expect(episodes.following(limit: 3).map(\.lastPathComponent) == ["b.mkv", "c.mkv", "d.mkv"])
    }

    @Test func episodeNameIsTheStemUpToTheEpisodeToken() {
        #expect(EpisodeList.episodeName(for: url("Northern.Line.S02E06.1080p.BluRay.x265.10bit-RLS.mkv")) == "Northern Line S02E06")
        #expect(EpisodeList.episodeName(for: url("northern_line_s1e2_720p.mkv")) == "northern line s1e2")
        #expect(EpisodeList.episodeName(for: url("Show.Name.E05.WEB.mkv")) == "Show Name E05")
        #expect(EpisodeList.episodeName(for: url("Some.Movie.2019.1080p.mkv")) == "Some Movie 2019 1080p")
        #expect(EpisodeList.episodeName(for: url("Northern.Line.S01E10.mkv")) == "Northern Line S01E10")
    }

    @Test func scanReadsOneFolderInAScratchDirectory() throws {
        let scratch = try ScratchDirectory("reel-episodes")
        defer { scratch.remove() }
        for name in ["Northern.Line.S01E01.mkv", "Northern.Line.S01E02.mkv", "Northern.Line.S01E10.mkv", "notes.txt"] {
            try Data("x".utf8).write(to: scratch.file(name))
        }
        try Data(count: 4_096).write(to: scratch.file("._Northern.Line.S01E02.mkv"))
        let sub = scratch.url.appending(path: "Season 2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appending(path: "Northern.Line.S02E01.mkv"))
        try FileManager.default.createDirectory(
            at: scratch.url.appending(path: "Folder.mkv", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let episodes = try EpisodeList.scan(current: scratch.file("Northern.Line.S01E02.mkv"))
        #expect(episodes.files.map(\.lastPathComponent) == [
            "Northern.Line.S01E01.mkv", "Northern.Line.S01E02.mkv", "Northern.Line.S01E10.mkv",
        ])
        #expect(episodes.next?.lastPathComponent == "Northern.Line.S01E10.mkv")
    }

    @Test func scanFindsTheFolderWhateverCaseThePathIsGivenIn() throws {
        let scratch = try ScratchDirectory("reel-episodes")
        defer { scratch.remove() }
        for name in ["Northern.Line.S01E01.mkv", "Northern.Line.S01E02.mkv", "Northern.Line.S01E03.mkv"] {
            try Data("x".utf8).write(to: scratch.file(name))
        }
        // The folder and the file name in another case, as a typed path or a drop may give them.
        let folder = scratch.url.deletingLastPathComponent()
            .appending(path: scratch.url.lastPathComponent.uppercased(), directoryHint: .isDirectory)
        let miscased = folder.appending(path: "northern.line.s01e02.MKV", directoryHint: .notDirectory)
        // A case-sensitive volume has no such file; the check only applies where the path resolves.
        guard FileManager.default.fileExists(atPath: miscased.path(percentEncoded: false)) else { return }
        let episodes = try EpisodeList.scan(current: miscased)
        #expect(episodes.count == 3)
        #expect(episodes.currentIndex == 1)
        #expect(episodes.next?.lastPathComponent == "Northern.Line.S01E03.mkv")
        #expect(episodes.previous?.lastPathComponent == "Northern.Line.S01E01.mkv")
        #expect(episodes.current?.lastPathComponent == "Northern.Line.S01E02.mkv")
    }

    @Test func scanOfAMissingFolderThrows() {
        #expect(throws: (any Error).self) {
            try EpisodeList.scan(current: URL(filePath: "/nonexistent-reel-folder-\(UUID().uuidString)/a.mkv"))
        }
    }
}
