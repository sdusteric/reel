import Foundation
import Testing
@testable import ReelCore

@Suite struct DolbyVisionPolicyTests {
    struct Row: Sendable, CustomTestStringConvertible {
        var profile: Int
        var compatibility: Int
        var base: DolbyVisionBase
        var tag: String
        var warning: Bool
        var line: String

        var testDescription: String { "profile \(profile) compatibility \(compatibility)" }
        var config: DolbyVisionConfig {
            DolbyVisionConfig(profile: profile, level: 6, rpu: true, el: profile == 7, bl: true, compatibilityID: compatibility)
        }
    }

    /// The section 7.8 table, one row per compatibility id and typical profile.
    static let table: [Row] = [
        Row(profile: 8, compatibility: 1, base: .hdr10, tag: "Dolby Vision", warning: false,
            line: "Playing the HDR10 base layer. The Dolby Vision layer is not applied."),
        Row(profile: 7, compatibility: 1, base: .hdr10, tag: "Dolby Vision", warning: false,
            line: "Playing the HDR10 base layer. The Dolby Vision layer is not applied."),
        Row(profile: 7, compatibility: 6, base: .hdr10, tag: "Dolby Vision", warning: false,
            line: "Playing the HDR10 base layer. The Dolby Vision layer is not applied."),
        Row(profile: 8, compatibility: 4, base: .hlg, tag: "Dolby Vision", warning: false,
            line: "Playing the HLG base layer. The Dolby Vision layer is not applied."),
        Row(profile: 8, compatibility: 2, base: .sdr, tag: "Dolby Vision", warning: false,
            line: "Playing the SDR base layer. The Dolby Vision layer is not applied."),
        Row(profile: 9, compatibility: 2, base: .sdr, tag: "Dolby Vision", warning: false,
            line: "Playing the SDR base layer. The Dolby Vision layer is not applied."),
        Row(profile: 5, compatibility: 0, base: .unsupported, tag: "Dolby Vision 5", warning: true,
            line: "Playing the base layer without its Dolby Vision colour data, so colours are wrong."),
        Row(profile: 10, compatibility: 0, base: .unsupported, tag: "Dolby Vision 10", warning: true,
            line: "Playing the base layer without its Dolby Vision colour data, so colours are wrong."),
    ]

    @Test(arguments: table)
    func compatibilityIDDecidesWhatPlays(_ row: Row) {
        let config = row.config
        #expect(DolbyVisionPolicy.base(for: config) == row.base)
        #expect(DolbyVisionPolicy.tag(for: config) == row.tag)
        #expect(DolbyVisionPolicy.showsWarning(for: config) == row.warning)
        #expect(DolbyVisionPolicy.videoInfoLine(for: config) == row.line)
    }

    @Test(arguments: [3, 5, 7, 15, 255])
    func unknownCompatibilityIDsAreNeverShownSilently(_ id: Int) {
        let config = DolbyVisionConfig(profile: 8, level: 6, rpu: true, el: false, bl: true, compatibilityID: id)
        #expect(DolbyVisionPolicy.base(for: config) == .unsupported)
        #expect(DolbyVisionPolicy.showsWarning(for: config))
    }

    @Test func onlyTheSDRBaseIsNotHDR() {
        #expect(DolbyVisionBase.allCases.filter { !$0.isHDR } == [.sdr])
    }

    @Test func noteCopyMatchesTheDesign() {
        #expect(DolbyVisionPolicy.noteTitle == "Dolby Vision profile 5 can't be shown correctly")
        #expect(DolbyVisionPolicy.noteBody == "Reel plays the picture without its Dolby Vision colour data, so colours look wrong, "
            + "often green or purple. Profile 8 files play correctly.")
        #expect(DolbyVisionPolicy.noteShowInfoButton == "Show Info")
        #expect(DolbyVisionPolicy.noteOKButton == "OK")
        #expect(DolbyVisionPolicy.noteSeconds == 10)
    }

    @Test func profileNameJoinsProfileAndCompatibility() {
        #expect(Self.table[0].config.profileName == "8.1")
        #expect(Self.table[3].config.profileName == "8.4")
        #expect(Self.table[6].config.profileName == "5")
    }

    @Test func mediaInfoWithoutTheRecordDecodesFromOldJSON() throws {
        let info = MediaInfo(url: URL(filePath: "/tmp/a.mkv"), formatName: "matroska,webm")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
        #expect(object["dolbyVision"] == nil)
        object.removeValue(forKey: "dolbyVision")
        let decoded = try JSONDecoder().decode(MediaInfo.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.dolbyVision == nil)

        var withRecord = info
        withRecord.dolbyVision = Self.table[0].config
        let roundTrip = try JSONDecoder().decode(MediaInfo.self, from: JSONEncoder().encode(withRecord))
        #expect(roundTrip.dolbyVision == Self.table[0].config)
    }
}
