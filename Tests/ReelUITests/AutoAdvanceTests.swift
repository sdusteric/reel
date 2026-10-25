import Foundation
import ReelCore
import Testing
@testable import ReelUI

/// A season folder in `scratch`: three episodes, the second one opened.
@MainActor
private struct Season {
    let scratch: UIScratch
    let first: URL
    let second: URL
    let third: URL

    init(_ scratch: UIScratch) throws {
        self.scratch = scratch
        first = try scratch.makeMediaFile("Show.S01E01.mkv")
        second = try scratch.makeMediaFile("Show.S01E02.mkv")
        third = try scratch.makeMediaFile("Show.S01E03.mkv")
    }
}

@MainActor
@Suite struct AutoAdvanceTests {
    /// Opens the middle episode and lets the engine report the end of the file.
    private func playToTheEnd(
        _ model: PlayerModel,
        _ boxes: EngineBox,
        file: URL
    ) async {
        await model.open(file)
        await waitUntil("playing") { model.playbackState == .playing }
        boxes.all[0].emit(.ended)
        await waitUntil("ended") { model.playbackState == .ended }
    }

    @Test func opensNextAfterCountdown() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox()
        let clock = TestClock()
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch, clock: clock)
        await playToTheEnd(model, boxes, file: season.second)

        #expect(model.autoAdvance.isActive)
        #expect(model.autoAdvance.nextURL == season.third.standardizedFileURL)
        #expect(model.autoAdvance.remainingLabel == "in 5 s")
        clock.advance(by: 4.9)
        model.autoAdvance.tick()
        #expect(model.autoAdvance.isActive, "still counting at 4.9 s")
        #expect(model.autoAdvance.remainingLabel == "in 1 s")
        clock.advance(by: 0.2)
        model.autoAdvance.tick()
        #expect(!model.autoAdvance.isActive)
        // The model makes the engine before it hashes the content key and calls `open`, so wait
        // for the call itself, not only for the second engine to exist.
        await waitUntil("the next file opens") { boxes.all.count == 2 && !boxes.all[1].calls.isEmpty }
        #expect(boxes.all.count == 2)
        #expect(boxes.all.last?.calls.first == .open(season.third.standardizedFileURL))
        await waitUntil("title") { model.title == "Show.S01E03.mkv" }
    }

    @Test func cancelStopsAutoAdvance() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox()
        let clock = TestClock()
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch, clock: clock)
        await playToTheEnd(model, boxes, file: season.second)

        model.autoAdvance.cancel()
        #expect(!model.autoAdvance.isActive)
        clock.advance(by: 30)
        model.autoAdvance.tick()
        #expect(boxes.all.count == 1, "no second engine: nothing opened")
        #expect(model.playbackState == .ended, "the last frame stays")
    }

    @Test func hoverPausesCountdown() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox()
        let clock = TestClock()
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch, clock: clock)
        await playToTheEnd(model, boxes, file: season.second)

        clock.advance(by: 2)
        model.autoAdvance.tick()
        model.autoAdvance.setHovered(true)
        clock.advance(by: 60)
        model.autoAdvance.tick()
        #expect(model.autoAdvance.isActive, "the countdown waits while the pointer is over the card")
        #expect(model.autoAdvance.remainingLabel == "in 3 s")
        model.autoAdvance.setHovered(false)
        clock.advance(by: 2.9)
        model.autoAdvance.tick()
        #expect(model.autoAdvance.isActive)
        clock.advance(by: 0.2)
        model.autoAdvance.tick()
        #expect(!model.autoAdvance.isActive)
        await waitUntil("the next file opens") { boxes.all.count == 2 }
    }

    @Test func playNowStartsTheNextFileAtOnce() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox()
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch)
        await playToTheEnd(model, boxes, file: season.second)
        model.autoAdvance.playNow()
        #expect(!model.autoAdvance.isActive)
        await waitUntil("the next file opens") { boxes.all.count == 2 }
    }

    @Test func noCardWhenLastEpisode() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox()
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch)
        await playToTheEnd(model, boxes, file: season.third)
        #expect(!model.autoAdvance.isActive)
        #expect(model.episodes?.next == nil)
        #expect(!model.hasNextEpisode)
        #expect(model.hasPreviousEpisode)
    }

    @Test func fileLoopDisablesAutoAdvance() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox()
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch)
        await model.open(season.second)
        await waitUntil("playing") { model.playbackState == .playing }
        model.toggleFileLoop()
        #expect(model.loop.fileLoop)
        boxes.all[0].emit(.ended)
        await waitUntil("ended") { model.playbackState == .ended }
        #expect(!model.autoAdvance.isActive, "a file loop disables auto-advance (D49)")
    }

    @Test func anABLoopDisablesAutoAdvance() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox()
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch)
        await model.open(season.second)
        await waitUntil("playing") { model.playbackState == .playing }
        model.toggleABLoop()
        #expect(model.loop.phase == .startSet, "an A point alone counts")
        boxes.all[0].emit(.ended)
        await waitUntil("ended") { model.playbackState == .ended }
        #expect(!model.autoAdvance.isActive)
    }

    @Test func theMenuSwitchTurnsItOff() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox()
        let (model, _, state) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch)
        model.setAutoAdvanceEnabled(false)
        #expect(state.state.autoAdvance == false)
        await playToTheEnd(model, boxes, file: season.second)
        #expect(!model.autoAdvance.isActive)
    }

    @Test func playingAgainRemovesTheCard() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox()
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch)
        await playToTheEnd(model, boxes, file: season.second)
        #expect(model.autoAdvance.isActive)
        model.togglePause()
        #expect(!model.autoAdvance.isActive, "Replay cancels the countdown")
    }

    @Test func trackChoiceCarriesToNextEpisode() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox { url in
            var options = FakeEngine.Options()
            // The same languages in a different order in the second file.
            let swapped = url.lastPathComponent.contains("E03")
            options.extraStreams = [
                StreamInfo(index: 2, kind: .audio, codec: "aac", timeBase: Rational(1, 1_000), language: "jpn", audio: AudioParameters(sampleRate: 48_000, channels: 2)),
                StreamInfo(index: 3, kind: .subtitle, codec: "ass", timeBase: Rational(1, 1_000), language: swapped ? "eng" : "zho"),
                StreamInfo(index: 4, kind: .subtitle, codec: "subrip", timeBase: Rational(1, 1_000), language: swapped ? "zho" : "eng"),
            ]
            return options
        }
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch)
        await model.open(season.second)
        await waitUntil("tracks") { model.tracks != nil }
        #expect(model.tracks?.selectedSubtitle == .embedded(streamIndex: 3), "Chinese first by default")

        // The user picks English subtitles and Japanese audio, shifts the subtitles and speeds up.
        model.selectSubtitle(.embedded(streamIndex: 4))
        model.selectAudio(2)
        model.setSubtitleDelay(0.5)
        model.setRate(1.5)
        await model.waitForEngineCommands()

        await model.playNextEpisode()
        #expect(boxes.all.count == 2)
        let next = boxes.all[1]
        await waitUntil("the choices are applied") {
            let calls = next.calls
            return calls.contains(.subtitle(.embedded(streamIndex: 3))) && calls.contains(.audioTrack(2))
        }
        await model.waitForEngineCommands()
        #expect(next.calls.contains(.subtitleDelay(0.5)), "a changed delay carries")
        #expect(next.calls.contains(.rate(1.5)), "speed carries for the session")
        #expect(model.tracks?.selectedSubtitle == .embedded(streamIndex: 3), "English is index 3 in the next file")
        #expect(model.subtitleDelay == 0.5)
        #expect(model.rate == 1.5)
    }

    @Test func unchosenTracksDoNotCarry() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox()
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch)
        await model.open(season.second)
        await waitUntil("tracks") { model.tracks != nil }
        await model.playNextEpisode()
        await model.waitForEngineCommands()
        let next = boxes.all[1]
        #expect(!next.calls.contains { if case .subtitle = $0 { return true } else { return false } })
        #expect(!next.calls.contains { if case .audioTrack = $0 { return true } else { return false } })
    }

    @Test func aFileThatFailsToOpenIsSkipped() async throws {
        let scratch = try UIScratch()
        defer { scratch.remove() }
        let season = try Season(scratch)
        let boxes = EngineBox { url in
            var options = FakeEngine.Options()
            if url.lastPathComponent.contains("E03") { options.openError = .unsupportedCodec("cinepak") }
            return options
        }
        let fourth = try scratch.makeMediaFile("Show.S01E04.mkv")
        let (model, _, _) = makeModel(engineFactory: { boxes.make($0) }, scratch: scratch)
        await model.open(season.second)
        await model.playNextEpisode()
        #expect(model.title == fourth.lastPathComponent)
        #expect(model.osd?.text.hasPrefix("Skipped Show.S01E03.mkv") == true)
    }
}
