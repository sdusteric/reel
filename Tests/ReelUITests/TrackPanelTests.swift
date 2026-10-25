import Foundation
import ReelCore
import Testing
@testable import ReelUI

@MainActor
@Suite struct TrackPanelTests {
    private static let base = Rational(1, 1_000)

    /// The mockup's file: two ASS tracks, English SRT and SDH, one PGS, and two more audio tracks.
    private static func options() -> FakeEngine.Options {
        var options = FakeEngine.Options()
        options.extraStreams = [
            StreamInfo(index: 2, kind: .audio, codec: "aac", timeBase: base, language: "jpn", audio: AudioParameters(sampleRate: 48_000, channels: 6, channelLayout: "5.1")),
            StreamInfo(index: 3, kind: .audio, codec: "aac", timeBase: base, language: "eng", title: "Commentary", audio: AudioParameters(sampleRate: 48_000, channels: 2, channelLayout: "stereo")),
            StreamInfo(index: 4, kind: .subtitle, codec: "ass", timeBase: base, language: "zho", title: "\u{7B80}\u{82F1}\u{53CC}\u{8BED}", isDefault: true),
            StreamInfo(index: 5, kind: .subtitle, codec: "ass", timeBase: base, language: "zh-Hant", title: "\u{7E41}\u{82F1}\u{96D9}\u{8A9E}"),
            StreamInfo(index: 6, kind: .subtitle, codec: "subrip", timeBase: base, language: "eng", title: "SDH", isHearingImpaired: true),
            StreamInfo(index: 7, kind: .subtitle, codec: "hdmv_pgs_subtitle", timeBase: base, language: "jpn"),
        ]
        return options
    }

    private func openedModel(_ scratch: UIScratch, options: FakeEngine.Options = TrackPanelTests.options()) async throws -> (PlayerModel, FakeEngine) {
        let engine = FakeEngine(options: options)
        let (model, _, _) = makeModel(engine: engine, scratch: scratch)
        await openAndSettle(model, try scratch.makeMediaFile("a.mkv"))
        await waitUntil("tracks") { model.tracks != nil }
        return (model, engine)
    }

    @Test func subtitleRowsListOffFirstThenEachTrackWithItsLabel() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _) = try await openedModel(scratch)
        let rows = TrackPanelContent.subtitleRows(model.tracks)
        #expect(rows.map(\.title) == ["Off", "Chinese (Simplified)", "Chinese (Traditional)", "English SDH", "Japanese"])
        #expect(rows[1].detail == "\u{7B80}\u{82F1}\u{53CC}\u{8BED} \u{00B7} Default")
        #expect(rows[1].tag == "ASS")
        #expect(rows[3].detail == "Hearing impaired")
        #expect(rows.last?.tag == "PGS")
        #expect(rows.first?.isSelected == false)
        #expect(rows[1].isSelected, "the Chinese track is the default choice")
        #expect(rows.filter(\.isSelected).count == 1)
        #expect(TrackPanelContent.countText(model.tracks?.subtitles.count ?? 0) == "4 tracks")
        #expect(TrackPanelContent.countText(1) == "1 track")
    }

    @Test func audioRowsCarryCodecAndChannelsAsTheTag() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _) = try await openedModel(scratch)
        let rows = TrackPanelContent.audioRows(model.tracks)
        #expect(rows.map(\.title) == ["Track 1", "Japanese", "English"])
        #expect(rows.map(\.tag) == ["AC-3 5.1", "AAC 5.1", "AAC 2.0"])
        #expect(rows[2].detail == "Commentary")
        #expect(rows.map(\.isSelected) == [true, false, false])
    }

    @Test func choosingATrackSelectsItAtOnceAndClosesThePanel() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, engine) = try await openedModel(scratch)
        model.openPanel(.subtitles)
        #expect(model.activePanel == .subtitles)
        #expect(model.chrome.isPanelOpen)
        #expect(model.panelHighlight == 1, "the selected row starts highlighted")
        let sdh = try #require(model.panelRows.first { $0.title == "English SDH" })
        model.choose(sdh)
        #expect(model.activePanel == nil, "the track panels close on choice")
        #expect(!model.chrome.isPanelOpen)
        #expect(model.tracks?.selectedSubtitle == .embedded(streamIndex: 6), "the check moves before the engine answers")
        await model.waitForEngineCommands()
        #expect(engine.calls.contains(.subtitle(.embedded(streamIndex: 6))))
    }

    @Test func offHidesTheSubtitlesAndAudioSwitchesWithoutMovingThePicture() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, engine) = try await openedModel(scratch)
        model.openPanel(.subtitles)
        model.choose(try #require(model.panelRows.first))
        #expect(model.tracks?.selectedSubtitle == .off)
        #expect(!model.subtitlesAreOn)
        #expect(model.subtitleAccessibilityValue == "Off")
        model.openPanel(.audio)
        model.choose(try #require(model.panelRows.first { $0.title == "Japanese" }))
        await model.waitForEngineCommands()
        #expect(engine.calls.contains(.audioTrack(2)))
        #expect(engine.seeks.isEmpty, "an audio switch does not seek")
        #expect(model.audioAccessibilityValue == "Japanese")
    }

    @Test func oneButtonOpensOnePanelAtATime() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _) = try await openedModel(scratch)
        model.togglePanel(.subtitles)
        model.togglePanel(.audio)
        #expect(model.activePanel == .audio)
        model.togglePanel(.audio)
        #expect(model.activePanel == nil, "the button again closes it")
        model.togglePanel(.speed)
        #expect(model.activePanel == .speed)
        model.closePanel()
        #expect(!model.chrome.isPanelOpen)
    }

    @Test func keyboardMovesChoosesAndCloses() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, engine) = try await openedModel(scratch)
        #expect(!model.handlePanelKey(.down), "no panel, no key")
        model.openPanel(.subtitles)
        #expect(model.panelHighlight == 1)
        model.handlePanelKey(.down)
        #expect(model.panelHighlight == 2)
        model.handlePanelKey(.up)
        model.handlePanelKey(.up)
        #expect(model.panelHighlight == 0)
        model.handlePanelKey(.up)
        #expect(model.panelHighlight == 0, "it stops at the first row")
        for _ in 0..<10 { model.handlePanelKey(.down) }
        #expect(model.panelHighlight == model.panelRows.count - 1)
        model.handlePanelKey(.confirm)
        #expect(model.activePanel == nil)
        await model.waitForEngineCommands()
        #expect(engine.calls.contains(.subtitle(.embedded(streamIndex: 7))))

        model.openPanel(.audio)
        model.handlePanelKey(.escape)
        #expect(model.activePanel == nil)
    }

    @Test func aFileWithoutSubtitlesShowsTheEmptyState() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        var plain = FakeEngine.Options()
        plain.extraStreams = []
        let (model, _) = try await openedModel(scratch, options: plain)
        #expect(TrackPanelContent.subtitleRows(model.tracks).isEmpty)
        model.openPanel(.subtitles)
        #expect(model.panelRows.isEmpty)
        #expect(model.panelHighlight == nil)
        #expect(!model.subtitlesAreOn)
        var added: [Int] = []
        model.onAddSubtitleFile = { added.append(1) }
        model.addSubtitleFile()
        #expect(added == [1], "Add Subtitle File is still there")
        #expect(model.activePanel == nil)
    }

    @Test func anExternalFileIsListedAndSelected() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, engine) = try await openedModel(scratch)
        let url = scratch.file("a.zh-Hans.srt")
        model.useSubtitleFile(url)
        await model.waitForEngineCommands()
        #expect(engine.calls.contains(.subtitle(.external(url))))
        await waitUntil("the engine lists the file") { model.tracks?.subtitles.contains { $0.id == .external(url) } == true }
        let rows = TrackPanelContent.subtitleRows(model.tracks)
        #expect(rows.last?.isSelected == true)
        #expect(rows.last?.detail?.contains("External: a.zh-Hans.srt") == true)
    }

    @Test func delaySizeAndSpeedSteppers() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, engine) = try await openedModel(scratch)
        model.stepSubtitleDelay(by: 1)
        model.stepSubtitleDelay(by: 5)
        #expect(model.subtitleDelay == 0.6, "0.1 s, and 0.5 s with Alt")
        model.stepAudioDelay(by: -1)
        #expect(model.audioDelay == -0.1)
        model.stepSubtitleSize(by: 1)
        #expect(model.subtitleStyle.size == 50)
        model.setRate(1.5)
        model.stepSpeed(by: 1)
        #expect(abs(model.rate - 1.55) < 0.000_1)
        #expect(model.osd == nil, "the panel shows the value, so no OSD")
        await model.waitForEngineCommands()
        #expect(engine.calls.contains(.subtitleDelay(0.1)) && engine.calls.contains(.subtitleDelay(0.6)))
        #expect(engine.calls.contains(.audioDelay(-0.1)))
        #expect(engine.calls.contains(.subtitleScale(50.0 / 45.0)))
        #expect(engine.calls.contains(.rate(1.5)))
    }

    @Test func keyboardCyclingNamesTheTrackInTheOSD() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, engine) = try await openedModel(scratch)
        model.cycleSubtitle()
        #expect(model.osd?.text == "Subtitles: Chinese (Traditional), ASS")
        model.cycleAudio()
        #expect(model.osd?.text == "Audio: Japanese, AAC 5.1")
        await model.waitForEngineCommands()
        #expect(engine.calls.contains(.audioTrack(2)))
        model.selectSubtitle(.off)
        model.cycleSubtitle()
        #expect(model.osd?.text.hasPrefix("Subtitles: ") == true)
        model.toggleSubtitlesVisible()
        #expect(model.osd?.text == "Subtitles Hidden")
        #expect(!model.subtitlesAreOn)
    }

    @Test func speedOSDsFollowTheRules() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let (model, _) = try await openedModel(scratch)
        model.doubleSpeed()
        #expect(model.osd?.text == "Speed 2\u{00D7}")
        model.halveSpeed()
        model.increaseSpeed()
        #expect(model.osd?.text == "Speed 1.1\u{00D7}")
        model.resetSpeed()
        #expect(model.rate == 1)
        #expect(model.speedAccessibilityValue == "1 times")
        model.setRate(9)
        #expect(model.rate == 4, "the range is 0.25 to 4")
    }
}
