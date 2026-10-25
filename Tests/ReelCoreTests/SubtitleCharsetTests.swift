import Foundation
import Testing
@testable import ReelCore

@Suite struct SubtitleCharsetTests {
    private let traditional = "1\n00:00:01,000 --> 00:00:03,000\n別回頭，繼續往前走。\nDon't look back.\n"
    private let simplified = "1\n00:00:01,000 --> 00:00:03,000\n别回头，继续往前走。\nDon't look back.\n"

    private func encoded(_ text: String, _ charset: SubtitleCharset) throws -> Data {
        try #require(text.data(using: charset.stringEncoding))
    }

    @Test func utf8DecodesAsUTF8() throws {
        let result = SubtitleCharsetDetector.decode(try encoded(simplified, .utf8), fileName: "movie.srt")
        #expect(result == DecodedSubtitleText(text: simplified, charset: .utf8, recognised: true))
    }

    @Test func byteOrderMarksSelectTheirCharsetAndAreRemoved() throws {
        let utf8 = Data([0xEF, 0xBB, 0xBF]) + (try encoded(simplified, .utf8))
        #expect(SubtitleCharsetDetector.decode(utf8).text == simplified)
        let le = Data([0xFF, 0xFE]) + (try encoded(simplified, .utf16LE))
        #expect(SubtitleCharsetDetector.decode(le) == DecodedSubtitleText(text: simplified, charset: .utf16LE, recognised: true))
        let be = Data([0xFE, 0xFF]) + (try encoded(simplified, .utf16BE))
        #expect(SubtitleCharsetDetector.decode(be).charset == .utf16BE)
        #expect(SubtitleCharsetDetector.decode(be).text == simplified)
    }

    @Test func gbkFileFallsBackToGB18030() throws {
        let data = try encoded(simplified, .gb18030)
        #expect(String(data: data, encoding: .utf8) == nil)
        let result = SubtitleCharsetDetector.decode(data, fileName: "subs_gbk.srt")
        #expect(result == DecodedSubtitleText(text: simplified, charset: .gb18030, recognised: true))
    }

    @Test func big5FileWithTraditionalNameUsesBig5() throws {
        let data = try encoded(traditional, .big5)
        let result = SubtitleCharsetDetector.decode(data, fileName: "subs_big5.cht.srt")
        #expect(result == DecodedSubtitleText(text: traditional, charset: .big5, recognised: true))
    }

    @Test func traditionalTitleAlsoSelectsBig5() throws {
        let data = try encoded(traditional, .big5)
        #expect(SubtitleCharsetDetector.decode(data, fileName: nil, title: "繁體中文").charset == .big5)
    }

    @Test func traditionalMarkersAreRecognised() {
        for name in ["a.cht.srt", "a.tc.srt", "a.BIG5.srt", "a.zh-Hant.srt", "a.zh-TW.srt", "a.zh_HK.srt"] {
            #expect(SubtitleCharsetDetector.saysTraditional(fileName: name, title: nil), "\(name)")
        }
        for name in ["a.chs.srt", "a.zh-Hans.srt", "a.srt", "watch.srt", "attic.srt"] {
            #expect(!SubtitleCharsetDetector.saysTraditional(fileName: name, title: nil), "\(name)")
        }
        #expect(SubtitleCharsetDetector.saysTraditional(fileName: nil, title: "繁英雙語"))
    }

    @Test func fallbackOrderFollowsTheDesign() {
        #expect(SubtitleCharsetDetector.fallbacks(fileName: "a.srt", title: nil) == [.gb18030, .latin1])
        #expect(SubtitleCharsetDetector.fallbacks(fileName: "a.cht.srt", title: nil) == [.big5, .latin1])
    }

    @Test func undecodableBytesEndAsLatin1AndUnrecognised() {
        // 0x80 is not a lead byte in GB18030, and a lone lead byte at the end is invalid in both.
        let data = Data([0x41, 0x80, 0x42, 0xFF])
        let result = SubtitleCharsetDetector.decode(data, fileName: "a.srt")
        #expect(result.charset == .latin1)
        #expect(!result.recognised)
        #expect(result.text.hasPrefix("A"))
    }

    @Test func charsetNamesAreIconvNames() {
        #expect(SubtitleCharset.gb18030.rawValue == "GB18030")
        #expect(SubtitleCharset.big5.rawValue == "BIG5")
        #expect(SubtitleCharset.utf8.rawValue == "UTF-8")
    }
}
