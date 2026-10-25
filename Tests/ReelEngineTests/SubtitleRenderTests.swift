import CoreGraphics
import CReelDeps
import Foundation
import ReelCore
import Testing
@testable import ReelEngine

/// A generated subtitle fixture (scripts/fixtures.sh). Records a failure naming the fix when missing.
func subtitleFixture(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
    let url = Fixture.directory.appending(path: name)
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
        Issue.record("Missing fixture \(name) in \(Fixture.directory.path(percentEncoded: false)): run scripts/fixtures.sh", sourceLocation: sourceLocation)
        throw FixtureMissing(name: name)
    }
    return url
}

/// Ink bounds of a rendered subtitle inside one horizontal band of the frame.
func inkBounds(_ bitmap: SubtitleBitmap?, rows: Range<Int>) -> PixelRect? {
    guard let bitmap, let bytes = SubtitleInk.rasterize(bitmap.image, width: bitmap.rect.width, height: bitmap.rect.height) else { return nil }
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    for row in 0..<bitmap.rect.height {
        let y = bitmap.rect.y + row
        guard rows.contains(y) else { continue }
        for column in 0..<bitmap.rect.width where bytes[(row * bitmap.rect.width + column) * 4 + 3] > 0 {
            let x = bitmap.rect.x + column
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }
    guard minX <= maxX else { return nil }
    return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

@Suite struct SubtitleRenderTests {
    static let frame = (width: 1920, height: 1080)
    /// subs_tracks.mkv: zho ASS 简英双语 is stream 3, the eng SRT stream 5.
    static let bilingualStream = 3

    /// Prefetches one embedded text track of `name` into a fresh store.
    static func prefetch(_ name: String, stream: Int) async throws -> SubtitleTrackStore {
        let store = SubtitleTrackStore()
        let prefetcher = SubtitlePrefetcher(url: try subtitleFixture(name), store: store, streams: [stream])
        prefetcher.start()
        let outcome = await prefetcher.wait()
        #expect(outcome.error == nil)
        #expect(outcome.streams == [stream])
        return store
    }

    static func settings(videoWidth: Int = 1280, videoHeight: Int = 720, bottomInset: Double? = nil, position: Double = SubtitleStyle.defaultPosition) -> SubtitleRenderSettings {
        SubtitleRenderSettings(
            frameWidth: frame.width,
            frameHeight: frame.height,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            position: position,
            bottomInset: bottomInset
        )
    }

    @Test func chineseASSRendersCentredInTheBottomBandWithEveryGlyph() async throws {
        let store = try await Self.prefetch("subs_tracks.mkv", stream: Self.bilingualStream)
        let renderer = try SubtitleRenderer()
        renderer.sync(with: store, track: .embedded(streamIndex: Self.bilingualStream))
        let result = renderer.render(at: .seconds(2), settings: Self.settings())
        let bitmap = try #require(result.bitmap)
        let ink = SubtitleInk.measure([(bitmap.image, bitmap.rect)], frameWidth: Self.frame.width, frameHeight: Self.frame.height)
        let bounds = try #require(ink.bounds)
        #expect(ink.pixels >= 3_000)
        #expect(renderer.diagnostics.missingGlyphs == 0, "libass log: \(renderer.diagnostics.log.suffix(5))")
        #expect(renderer.diagnostics.fonts.contains { $0.hasPrefix("PingFang") }, "fonts \(renderer.diagnostics.fonts)")
        #expect(renderer.diagnostics.substitutions.isEmpty)
        #expect(abs(bounds.centerX - 960) <= 0.02 * 1920, "bbox \(bounds)")
        // The bottom 15% of the frame: from y 918 to the bottom edge.
        #expect(bounds.maxY >= 918 && bounds.maxY <= 1048, "bbox \(bounds)")
        #expect(bounds.y >= 1080 * 70 / 100, "two lines stay low in the frame: \(bounds)")
    }

    @Test func nothingRendersBeforeTheFirstEvent() async throws {
        let store = try await Self.prefetch("subs_tracks.mkv", stream: Self.bilingualStream)
        let renderer = try SubtitleRenderer()
        renderer.sync(with: store, track: .embedded(streamIndex: Self.bilingualStream))
        #expect(renderer.render(at: .seconds(0.5), settings: Self.settings()).bitmap == nil)
        #expect(renderer.render(at: .seconds(3.5), settings: Self.settings()).bitmap == nil)
        #expect(renderer.render(at: .seconds(2), settings: Self.settings()).bitmap != nil)
    }

    @Test func positionedSignStaysAtTheTopWhileBottomLinesLift() throws {
        let url = try subtitleFixture("subs_ass_signs.ass")
        let store = SubtitleTrackStore()
        let loaded = try ExternalSubtitleLoader.load(url, into: store)
        #expect(loaded.events.count == 2)
        let renderer = try SubtitleRenderer()
        renderer.sync(with: store, track: loaded.trackID)
        let topBand = 0..<(Self.frame.height * 15 / 100)
        let bottomBand = (Self.frame.height / 2)..<Self.frame.height

        let resting = renderer.render(at: .seconds(2), settings: Self.settings()).bitmap
        let restingSign = try #require(inkBounds(resting, rows: topBand))
        let restingLine = try #require(inkBounds(resting, rows: bottomBand))

        // The controller's top edge 300 px above the frame bottom.
        let lifted = renderer.render(at: .seconds(2), settings: Self.settings(bottomInset: 300)).bitmap
        let liftedSign = try #require(inkBounds(lifted, rows: topBand))
        let liftedLine = try #require(inkBounds(lifted, rows: bottomBand))
        #expect(liftedSign == restingSign, "the \\pos sign must not move")
        #expect(liftedLine.maxY < restingLine.maxY - 100, "bottom line moved from \(restingLine) to \(liftedLine)")
        #expect(liftedLine.maxY <= Self.frame.height - 300 + 8, "bottom edge at or above the controller: \(liftedLine)")

        // The user's position (r / R) also moves only the bottom line.
        let raised = renderer.render(at: .seconds(2), settings: Self.settings(position: 90)).bitmap
        #expect(inkBounds(raised, rows: topBand) == restingSign)
        let raisedLine = try #require(inkBounds(raised, rows: bottomBand))
        #expect(raisedLine.maxY < restingLine.maxY - 50)
        #expect(renderer.diagnostics.missingGlyphs == 0)
    }

    @Test func unstyledSidecarUsesReelsDefaultStyleAtSize45() throws {
        let url = try subtitleFixture("subs_tracks.zh-Hans.srt")
        let store = SubtitleTrackStore()
        let loaded = try ExternalSubtitleLoader.load(url, into: store)
        #expect(loaded.format == .srt)
        let renderer = try SubtitleRenderer()
        renderer.sync(with: store, track: loaded.trackID)
        let bitmap = try #require(renderer.render(at: .seconds(2), settings: Self.settings()).bitmap)
        let bounds = try #require(SubtitleInk.measure([(bitmap.image, bitmap.rect)], frameWidth: 1920, frameHeight: 1080).bounds)
        #expect(renderer.diagnostics.missingGlyphs == 0)
        #expect(abs(bounds.centerX - 960) <= 0.02 * 1920)
        // Two lines at 67.5 px (45 on the 720 reference) with outline and shadow.
        #expect((110...230).contains(bounds.height), "bbox \(bounds)")
        // Bottom margin 40 on the 720 reference is 60 px at 1080.
        #expect(abs(Double(1080 - bounds.maxY) - 60) <= 15, "bbox \(bounds)")
        // A larger size factor makes the lines taller.
        let larger = SubtitleRenderSettings(frameWidth: 1920, frameHeight: 1080, videoWidth: 1280, videoHeight: 720, scale: 1.5)
        let grown = try #require(renderer.render(at: .seconds(2), settings: larger).bitmap)
        #expect(grown.rect.height > bitmap.rect.height + 30)
    }

    @Test func unchangedFramesReuseTheBlendedImage() async throws {
        let store = try await Self.prefetch("subs_tracks.mkv", stream: Self.bilingualStream)
        let renderer = try SubtitleRenderer()
        renderer.sync(with: store, track: .embedded(streamIndex: Self.bilingualStream))
        let first = renderer.render(at: .seconds(2), settings: Self.settings())
        let blends = renderer.blendCount
        let second = renderer.render(at: .seconds(2.04), settings: Self.settings())
        #expect(first.changed == 2)
        #expect(second.changed == 0)
        #expect(renderer.blendCount == blends)
        #expect(second.bitmap?.rect == first.bitmap?.rect)
    }

    @Test func steadyStateRenderAt1080pStaysWithinOneFrame() async throws {
        let store = try await Self.prefetch("subs_tracks.mkv", stream: Self.bilingualStream)
        let renderer = try SubtitleRenderer()
        renderer.sync(with: store, track: .embedded(streamIndex: Self.bilingualStream))
        let settings = Self.settings()
        _ = renderer.render(at: .seconds(2), settings: settings)
        var samples: [Double] = []
        for frame in 0..<100 {
            let started = ContinuousClock.now
            _ = renderer.render(at: .seconds(2 + Double(frame) / 24), settings: settings)
            let elapsed = ContinuousClock.now - started
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000)
        }
        let sorted = samples.sorted()
        let p95 = sorted[Int((0.95 * Double(sorted.count)).rounded(.up)) - 1]
        #expect(p95 <= 16, "render p95 \(p95) ms")
    }

    @Test func storeKeepsEventsOnceInTimeOrderWithNextAndPrevious() async throws {
        let store = try await Self.prefetch("subs_tracks.mkv", stream: Self.bilingualStream)
        let id = TrackID.embedded(streamIndex: Self.bilingualStream)
        let track = try #require(store.track(id))
        #expect(track.isComplete)
        #expect(track.events.count == 3)
        #expect(track.events.map(\.event.start) == [.seconds(1), .seconds(4), .seconds(4)])
        #expect(store.add(track.events.map(\.event), to: id) == 0, "a second pass adds nothing")
        #expect(store.nextEventStart(id, after: .seconds(2)) == .seconds(4))
        #expect(store.previousEventStart(id, before: .seconds(5)) == .seconds(1))
        #expect(store.events(id, at: .seconds(5)).count == 2)
        #expect(store.events(id, at: .seconds(3.5)).isEmpty)
        #expect(track.events[0].event.plainText.hasPrefix("别回头"))
    }

    @Test func prefetcherReadsEveryTextTrackAndSkipsAudioAndVideo() async throws {
        let store = SubtitleTrackStore()
        let prefetcher = SubtitlePrefetcher(url: try subtitleFixture("subs_tracks.mkv"), store: store)
        prefetcher.start()
        let outcome = await prefetcher.wait()
        #expect(outcome.streams == [3, 4, 5, 6])
        #expect(outcome.error == nil)
        #expect(outcome.packets == 3 + 3 + 2 + 2)
        #expect(store.track(.embedded(streamIndex: 5))?.format == .srt)
        #expect(store.track(.embedded(streamIndex: 4))?.events.first?.event.plainText.hasPrefix("別回頭") == true)
    }

    @Test func cancelledPrefetchStopsAndKeepsWhatItRead() async throws {
        let store = SubtitleTrackStore()
        let prefetcher = SubtitlePrefetcher(url: try subtitleFixture("subs_tracks.mkv"), store: store)
        prefetcher.cancel()
        prefetcher.start()
        let outcome = await prefetcher.wait()
        #expect(outcome.cancelled)
        #expect(outcome.error == nil)
        #expect(prefetcher.isFinished)
        #expect(store.trackIDs.allSatisfy { store.track($0)?.isComplete == false })
    }

    /// Writes `text` as a one-event SRT named `name` in a fresh temporary folder.
    static func writeSRT(_ name: String, text: String) throws -> (file: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "reel-srt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try Data("1\n00:00:01,000 --> 00:00:04,000\n\(text)\n".utf8).write(to: file)
        return (file, folder)
    }

    @Test(arguments: [
        ("movie.zh-Hans.srt", "别回头，继续往前走。", "PingFangSC-Medium"),
        ("movie.zh-Hant.srt", "別回頭，繼續往前走。𠮷", "PingFangTC-Medium"),
        ("movie.zh-HK.srt", "佢哋喺度等緊𨋢。𠮷 𡃁", "PingFangHK-Medium"),
    ])
    func unstyledChineseUsesThePingFangFaceOfItsScript(name: String, text: String, face: String) throws {
        let written = try Self.writeSRT(name, text: text)
        defer { try? FileManager.default.removeItem(at: written.folder) }
        let store = SubtitleTrackStore()
        let loaded = try ExternalSubtitleLoader.load(written.file, into: store)
        let renderer = try SubtitleRenderer()
        renderer.sync(with: store, track: loaded.trackID)
        let bitmap = renderer.render(at: .seconds(2), settings: Self.settings()).bitmap
        #expect(bitmap != nil)
        #expect(renderer.diagnostics.fonts == [face], "fonts \(renderer.diagnostics.fonts)")
        #expect(renderer.diagnostics.missingGlyphs == 0, "libass log: \(renderer.diagnostics.log.suffix(5))")
        #expect(renderer.diagnostics.substitutions.isEmpty)
    }

    /// Design 8.5: a lifted line's visible bottom edge (outline and shadow included) sits at the
    /// inset the window asks for, which already holds the 12 pt gap above the controller.
    @Test func liftedLinesShowTheirVisibleBottomAtTheInset() async throws {
        let written = try Self.writeSRT("movie.zh-Hans.srt", text: "别回头，继续往前走。\nDon't look back. Keep walking.")
        defer { try? FileManager.default.removeItem(at: written.folder) }
        let sidecar = SubtitleTrackStore()
        let loaded = try ExternalSubtitleLoader.load(written.file, into: sidecar)
        let embedded = try await Self.prefetch("subs_tracks.mkv", stream: Self.bilingualStream)
        let tracks = [(sidecar, loaded.trackID), (embedded, TrackID.embedded(streamIndex: Self.bilingualStream))]
        for (store, id) in tracks {
            let renderer = try SubtitleRenderer()
            renderer.sync(with: store, track: id)
            for (width, height) in [(1920, 1080), (2560, 1440)] {
                let inset = 300.0
                let settings = SubtitleRenderSettings(frameWidth: width, frameHeight: height, videoWidth: 1920, videoHeight: 1080, bottomInset: inset)
                let bounds = try #require(inkBounds(renderer.render(at: .seconds(2), settings: settings).bitmap, rows: 0..<height))
                let visibleBottom = Double(bounds.y + bounds.height)
                #expect(abs(visibleBottom - (Double(height) - inset)) <= 2, "\(id) at \(width)x\(height): ink ends at \(visibleBottom)")
            }
        }
    }

    @Test func rebuiltPingFangIsACollectionOfFourMediumFaces() throws {
        let collection = try #require(SubtitleFonts.pingFang)
        #expect(collection.families == ["pingfang sc", "pingfang tc", "pingfang hk", "pingfang mo"])
        let data = collection.data
        #expect(data.prefix(4) == Data("ttcf".utf8))
        #expect(data[8..<12] == Data([0, 0, 0, 4]))
        #expect(SubtitleFonts.substitutions.isEmpty)
    }

    @Test func linePositionCombinesUserPositionAndLift() throws {
        var track = ASS_Track()
        track.PlayResY = 288
        let plain = SubtitleRenderer.linePosition(settings: Self.settings(), track: track, unstyled: true)
        #expect(plain == 0)
        let raised = SubtitleRenderer.linePosition(settings: Self.settings(position: 95), track: track, unstyled: true)
        #expect(raised == 5)
        // Default bottom at 1080 - 60 = 1020; a lift to 1080 - 200 = 880 is 140 / 1020 of the height.
        let lifted = SubtitleRenderer.linePosition(settings: Self.settings(bottomInset: 200), track: track, unstyled: true)
        #expect(abs(lifted - 100 * 140 / 1020) < 0.5)
        // A lift lower than the default position changes nothing.
        #expect(SubtitleRenderer.linePosition(settings: Self.settings(bottomInset: 20), track: track, unstyled: true) == 0)
    }
}
