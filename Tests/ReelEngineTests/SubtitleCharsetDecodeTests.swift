import Foundation
import ReelCore
import Testing
@testable import ReelEngine

@Suite struct SubtitleCharsetDecodeTests {
    static func text(of loaded: LoadedExternalSubtitle) -> String {
        loaded.events.map(\.plainText).joined(separator: "\n")
    }

    static let expectedText = """
        別回頭，繼續往前走。
        Don't look back. Keep walking.
        我們終於到了北線。
        We finally made it to the Northern Line.
        """

    @Test func utf8SidecarStaysUTF8() throws {
        let loaded = try ExternalSubtitleLoader.load(subtitleFixture("subs_utf8.srt"))
        #expect(loaded.charset == .utf8)
        #expect(loaded.charsetRecognised)
        #expect(Self.text(of: loaded) == Self.expectedText)
        #expect(loaded.events.map(\.start) == [.seconds(1), .seconds(4)])
        #expect(loaded.events.map(\.end) == [.seconds(3), .seconds(6)])
    }

    @Test func gbkSidecarDecodesAsGB18030WithTheSameText() throws {
        let reference = try ExternalSubtitleLoader.load(subtitleFixture("subs_utf8.srt"))
        let loaded = try ExternalSubtitleLoader.load(subtitleFixture("subs_gbk.srt"))
        #expect(loaded.charset == .gb18030)
        #expect(loaded.charset.rawValue == "GB18030")
        #expect(loaded.charsetRecognised)
        #expect(Self.text(of: loaded) == Self.text(of: reference))
        #expect(loaded.events.map(\.time) == reference.events.map(\.time))
    }

    @Test func big5SidecarNamedTraditionalDecodesAsBig5WithTheSameText() throws {
        let reference = try ExternalSubtitleLoader.load(subtitleFixture("subs_utf8.srt"))
        let loaded = try ExternalSubtitleLoader.load(subtitleFixture("subs_big5.cht.srt"))
        #expect(loaded.charset == .big5)
        #expect(loaded.charset.rawValue == "BIG5")
        #expect(Self.text(of: loaded) == Self.text(of: reference))
    }

    @Test func traditionalTitleChoosesBig5ForAFileWithoutATag() throws {
        let data = try Data(contentsOf: subtitleFixture("subs_big5.cht.srt"))
        let loaded = try ExternalSubtitleLoader.load(data: data, url: URL(filePath: "/tmp/episode.srt"), title: "繁體中文")
        #expect(loaded.charset == .big5)
        #expect(Self.text(of: loaded) == Self.expectedText)
    }

    @Test func utf16WithAByteOrderMarkIsReadAndReported() throws {
        let utf8 = try Data(contentsOf: subtitleFixture("subs_utf8.srt"))
        let text = try #require(String(data: utf8, encoding: .utf8))
        var data = Data([0xFF, 0xFE])
        data.append(try #require(text.data(using: .utf16LittleEndian)))
        let loaded = try ExternalSubtitleLoader.load(data: data, url: URL(filePath: "/tmp/movie.en.srt"))
        #expect(loaded.charset == .utf16LE)
        #expect(Self.text(of: loaded) == Self.expectedText)
    }

    @Test func undecodableBytesFallBackToLatin1AndAreFlagged() throws {
        var data = Data("1\n00:00:01,000 --> 00:00:02,000\n".utf8)
        data.append(contentsOf: [0x41, 0xFF, 0xFF, 0x80, 0x42, 0x0A, 0x0A])
        let loaded = try ExternalSubtitleLoader.load(data: data, url: URL(filePath: "/tmp/broken.srt"))
        #expect(loaded.charset == .latin1)
        #expect(!loaded.charsetRecognised)
        #expect(loaded.events.count == 1)
        #expect(loaded.events.first?.plainText == "A\u{FF}\u{FF}\u{80}B")
    }

    @Test func embeddedDecoderFallsBackAndDecodesItsHistoryAgain() throws {
        let decoder = try Self.subripDecoder()
        let ascii = SubtitleSourcePacket(data: Data("Hello".utf8), pts: 1_000, duration: 1_000)
        #expect(try decoder.decodeText(ascii) == .added([SubtitleTextEvent(start: .seconds(1), end: .seconds(2), fields: "0,Default,,0,0,0,,Hello")]))
        let gbk = try #require("我们终于到了北线。".data(using: SubtitleCharset.gb18030.stringEncoding))
        let update = try decoder.decodeText(SubtitleSourcePacket(data: gbk, pts: 4_000, duration: 2_000))
        guard case .replaced(let events, let charset) = update else {
            Issue.record("expected the decoder to switch charset, got \(update)")
            return
        }
        #expect(charset == .gb18030)
        #expect(decoder.charset == .gb18030)
        #expect(events.map(\.plainText) == ["Hello", "我们终于到了北线。"])
    }

    @Test func feedsOfOneTrackAgreeOnTheCharsetThroughTheStore() throws {
        let store = SubtitleTrackStore()
        let id = TrackID.embedded(streamIndex: 5)
        let prefetch = SubtitleTextFeed(decoder: try Self.subripDecoder(), track: id, store: store)
        let main = SubtitleTextFeed(decoder: try Self.subripDecoder(), track: id, store: store)
        let gbk = try #require("别回头".data(using: SubtitleCharset.gb18030.stringEncoding))
        let later = try #require("北线".data(using: SubtitleCharset.gb18030.stringEncoding))

        try prefetch.feed(SubtitleSourcePacket(data: Data("Hi".utf8), pts: 500, duration: 300))
        try prefetch.feed(SubtitleSourcePacket(data: gbk, pts: 1_000, duration: 1_000))
        let afterSwitch = try #require(store.track(id))
        #expect(afterSwitch.charset == .gb18030)
        #expect(afterSwitch.events.map(\.event.plainText) == ["Hi", "别回头"])

        // The main demuxer's feed adopts GB18030 instead of resetting the track again.
        try main.feed(SubtitleSourcePacket(data: later, pts: 4_000, duration: 1_000))
        let merged = try #require(store.track(id))
        #expect(merged.epoch == afterSwitch.epoch)
        #expect(main.decoder.charset == .gb18030)
        #expect(merged.events.map(\.event.plainText) == ["Hi", "别回头", "北线"])
    }

    /// A subrip decoder from the eng SRT stream of subs_tracks.mkv (time base 1/1000).
    static func subripDecoder() throws -> SubtitleDecoder {
        let source = try MediaSource(url: subtitleFixture("subs_tracks.mkv"))
        let stream = try #require(source.stream(5))
        let decoder = try SubtitleDecoder(parameters: CodecParameters(copying: stream), fileName: "subs_tracks.mkv")
        #expect(decoder.format == .srt)
        #expect(decoder.charset == .utf8)
        return decoder
    }
}
