import AppKit
import CoreMedia
import Foundation
import MediaPlayer
import ReelCore
import ReelUI
import Synchronization
import Testing
@testable import Reel

/// A `PlayerEngine` that records commands and answers with plausible events. No decoding, no
/// audio, no window.
nonisolated final class StubEngine: PlayerEngine {
    enum Call: Equatable {
        case open(URL), play, pause, seek(SeekRequest), close
    }

    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let log = Mutex<[Call]>([])

    init() {
        (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
    }

    var calls: [Call] { log.withLock { $0 } }

    /// Sends an event as the engine would (M3: `.dynamicRange`, `.problem`, ...).
    func emit(_ event: EngineEvent) {
        continuation.yield(event)
    }

    private func record(_ call: Call) {
        log.withLock { $0.append(call) }
    }

    func open(_ url: URL) async throws -> MediaInfo {
        record(.open(url))
        let video = StreamInfo(
            index: 0, kind: .video, codec: "hevc", timeBase: Rational(1, 1_000),
            video: VideoParameters(width: 1920, height: 1080, frameRate: Rational(24, 1), bitDepth: 10)
        )
        let info = MediaInfo(
            url: url, formatName: "matroska,webm", duration: .seconds(600), streams: [video],
            videoStreamIndex: 0, audioStreamIndex: nil, videoDecoder: .hardware, keyframeCount: 60
        )
        continuation.yield(.opened(info))
        continuation.yield(.tracksChanged(TrackState(info: info)))
        continuation.yield(.stateChanged(.paused))
        return info
    }

    func play() async {
        record(.play)
        continuation.yield(.stateChanged(.playing))
    }

    func pause() async {
        record(.pause)
        continuation.yield(.stateChanged(.paused))
    }

    func seek(_ request: SeekRequest) async { record(.seek(request)) }
    func setVolume(_ volume: Double) async {}
    func setMuted(_ muted: Bool) async {}
    func setTimeUpdateInterval(_ seconds: Double) async {}

    func close() async {
        record(.close)
        continuation.finish()
    }
}

/// A clock for `AppScheduling`: nothing runs until the test advances it.
final class FakeScheduler: AppScheduling {
    private struct Item {
        var id: Int
        var at: TimeInterval
        var action: @MainActor () -> Void
    }

    private(set) var now: TimeInterval = 0
    private var items: [Item] = []
    private var nextID = 0

    var pendingCount: Int { items.count }

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledAction {
        nextID += 1
        let id = nextID
        items.append(Item(id: id, at: now + seconds, action: action))
        return ScheduledAction { [weak self] in self?.items.removeAll { $0.id == id } }
    }

    /// Runs everything due by `now + seconds`, in time order, including work scheduled meanwhile.
    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = items.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            items.removeAll { $0.id == next.id }
            now = next.at
            next.action()
        }
        now = target
    }
}

/// What a fake screen reports; tests change it between notifications.
final class DisplayBox {
    var value: DisplayCapabilities

    init(_ value: DisplayCapabilities) {
        self.value = value
    }
}

/// Stands in for `MPNowPlayingInfoCenter`.
final class FakeNowPlayingPublisher: NowPlayingPublishing {
    var published: [NowPlayingState?] = []

    func publish(_ state: NowPlayingState?) {
        published.append(state)
    }
}

/// Stands in for `MPRemoteCommandCenter`.
final class FakeRemoteCommands: RemoteCommandRegistering {
    var handler: (@MainActor (RemoteCommand) -> Void)?
    var registrations = 0
    var unregistrations = 0
    var episodeCommands: (next: Bool, previous: Bool)?

    func register(handler: @escaping @MainActor (RemoteCommand) -> Void) {
        registrations += 1
        self.handler = handler
    }

    func setEpisodeCommandsEnabled(next: Bool, previous: Bool) {
        episodeCommands = (next, previous)
    }

    func unregister() {
        unregistrations += 1
        handler = nil
    }
}

/// A temp folder of small stand-in video files, removed by its exact path.
struct AppScratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "reel-app-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func makeFile(_ name: String) throws -> URL {
        let file = url.appending(path: name, directoryHint: .notDirectory)
        try Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: file)
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Polls `condition` until it holds or 20 seconds pass.
func eventually(_ description: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
    // Bounds a hang only; the model's open runs detached steps a loaded test run can delay.
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// The stub engines a model made, in order.
nonisolated final class EngineList: Sendable {
    private let engines = Mutex<[StubEngine]>([])

    func add(_ engine: StubEngine) { engines.withLock { $0.append(engine) } }
    var all: [StubEngine] { engines.withLock { $0 } }
}

/// A model on stub engines, one per opened file, over the real folder scan.
func makeAppModel(engines: EngineList = EngineList()) -> PlayerModel {
    let dependencies = PlayerModel.Dependencies(
        makeEngine: { _ in
            let engine = StubEngine()
            engines.add(engine)
            return engine
        },
        episodeList: { url in try? EpisodeList.scan(current: url) },
        sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) }
    )
    return PlayerModel(dependencies: dependencies)
}

@Suite struct NowPlayingTests {
    static func state(title: String = "Northern Line S01E02", elapsed: Double = 0, playing: Bool = true) -> NowPlayingState {
        NowPlayingState(title: title, duration: 600, elapsed: elapsed, rate: 1, isPlaying: playing, hasNext: true, hasPrevious: false, artwork: nil)
    }

    @Test func registersOnlyWhileAFileIsOpenAndReleasesTheKeysOnClose() throws {
        let publisher = FakeNowPlayingPublisher()
        let commands = FakeRemoteCommands()
        let nowPlaying = NowPlaying(publisher: publisher, commands: commands, sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) })
        let model = makeAppModel()
        nowPlaying.update(nil, model: model)
        #expect(commands.registrations == 0 && publisher.published.isEmpty, "nothing open: the media keys stay free (D44)")

        nowPlaying.update(Self.state(), model: model)
        #expect(nowPlaying.isRegistered)
        #expect(commands.registrations == 1)
        #expect(publisher.published.count == 1)
        nowPlaying.update(Self.state(), model: model)
        #expect(publisher.published.count == 1, "an unchanged state is not published again")
        nowPlaying.update(Self.state(elapsed: 12, playing: false), model: model)
        #expect(publisher.published.count == 2)
        #expect(commands.registrations == 1, "registered once per open file")
        #expect(commands.episodeCommands?.next == true && commands.episodeCommands?.previous == false)

        nowPlaying.clear()
        #expect(!nowPlaying.isRegistered)
        #expect(commands.unregistrations == 1)
        #expect(publisher.published.last == .some(nil), "close clears the info")
    }

    @Test func stateNamesTheEpisodeAndFollowsThePlayer() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        for name in ["Northern.Line.S01E01.mkv", "Northern.Line.S01E03.mkv"] { _ = try scratch.makeFile(name) }
        let file = try scratch.makeFile("Northern.Line.S01E02.1080p.mkv")
        let model = makeAppModel()
        #expect(NowPlaying.state(for: model, artwork: nil) == nil)
        await model.open(file)
        await eventually("playing") { model.playbackState == .playing }
        await eventually("episodes") { model.hasNextEpisode }
        let state = try #require(NowPlaying.state(for: model, artwork: Data([1, 2, 3])))
        #expect(state.title == "Northern Line S01E02")
        #expect(state.duration == 600)
        #expect(state.isPlaying)
        #expect(state.hasNext && state.hasPrevious)
        #expect(state.artwork == Data([1, 2, 3]))
    }

    @Test func remoteCommandsDriveThePlayer() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let first = try scratch.makeFile("Northern.Line.S01E01.mkv")
        let second = try scratch.makeFile("Northern.Line.S01E02.mkv")
        let engines = EngineList()
        let model = makeAppModel(engines: engines)
        await model.open(first)
        await eventually("playing") { model.playbackState == .playing }
        let commands = FakeRemoteCommands()
        let nowPlaying = NowPlaying(publisher: FakeNowPlayingPublisher(), commands: commands, sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) })
        nowPlaying.update(NowPlaying.state(for: model, artwork: nil), model: model)
        let handler = try #require(commands.handler)
        let engine = try #require(engines.all.first)

        handler(.pause)
        await eventually("paused") { engine.calls.contains(.pause) }
        handler(.togglePlayPause)
        await eventually("playing again") { engine.calls.filter { $0 == .play }.count >= 2 }
        handler(.changePosition(30))
        await eventually("seek to 30 s") { engine.calls.contains { if case .seek(let request) = $0 { request.target == .seconds(30) } else { false } } }
        handler(.nextTrack)
        await eventually("next episode opened") { engines.all.count == 2 }
        guard case .open(let opened)? = engines.all.last?.calls.first else {
            Issue.record("the second engine did not open a file")
            return
        }
        #expect(opened.lastPathComponent == second.lastPathComponent)
    }
}

@Suite struct PictureInPictureTests {
    @Test func playbackDelegateMapsToThePlayerWithoutStartingPiP() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let engines = EngineList()
        let model = makeAppModel(engines: engines)
        await model.open(try scratch.makeFile("movie.mkv"))
        await eventually("playing") { model.playbackState == .playing }
        let engine = try #require(engines.all.first)
        let pip = PictureInPicture(model: model, log: .disabled)
        #expect(!pip.isActive, "no controller exists until the user asks")

        pip.refresh()
        #expect(pip.currentSnapshot.duration == 600)
        #expect(!pip.currentSnapshot.isPaused)
        #expect(PictureInPicture.timeRange(duration: 600) == CMTimeRange(start: .zero, duration: CMTime(seconds: 600, preferredTimescale: 600)))
        #expect(PictureInPicture.timeRange(duration: nil).duration == .positiveInfinity)

        pip.setPlaying(false)
        await eventually("paused") { engine.calls.contains(.pause) }
        #expect(pip.currentSnapshot.isPaused)
        pip.skip(by: 10)
        await eventually("skip seek") { engine.calls.contains { if case .seek = $0 { true } else { false } } }

        var reported: [Bool] = []
        pip.onActiveChange = { reported.append($0) }
        pip.didChange(active: true)
        #expect(model.isPictureInPictureActive)
        pip.didChange(active: false)
        #expect(!model.isPictureInPictureActive)
        #expect(reported == [true, false], "the engine is told to start and stop compositing subtitles")
    }

    @Test func theWindowIsHiddenBeforeThePlaceholderIsBuilt() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let model = makeAppModel()
        await model.open(try scratch.makeFile("movie.mkv"))
        await eventually("playing") { model.playbackState == .playing }
        let pip = PictureInPicture(model: model, log: .disabled)
        pip.hidesWindowDuringPiP = { true }
        var placeholderShownWhenReported: [Bool] = []
        pip.onActiveChange = { _ in placeholderShownWhenReported.append(model.isPictureInPictureActive) }
        pip.didChange(active: true)
        #expect(placeholderShownWhenReported == [false], "the PiP crop workaround hides the window first")
        #expect(model.isPictureInPictureActive)
        #expect(model.pictureInPictureSnapshot == nil, "no blurred snapshot for a window nobody sees")
    }

    @Test func theToggleAsksTheAppOnlyWithAFileOpen() async throws {
        let model = makeAppModel()
        var requests: [Bool] = []
        model.onPictureInPictureRequest = { requests.append($0) }
        model.togglePictureInPicture()
        #expect(requests.isEmpty)
        let scratch = try AppScratch()
        defer { scratch.remove() }
        await model.open(try scratch.makeFile("movie.mkv"))
        await eventually("playing") { model.playbackState == .playing }
        model.togglePictureInPicture()
        #expect(requests == [true])
    }
}

// MARK: M3 app shell (design 7.7 to 7.11, 9.11, 9.13, 10, 11.1)

@Suite struct MainMenuM3Tests {
    static func item(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        for entry in menu.items {
            if entry.title == title { return entry }
            if let submenu = entry.submenu, let found = item(title, in: submenu) { return found }
        }
        return nil
    }

    @Test func videoInfoAndAddSubtitleFileShowTheirShortcuts() throws {
        let menu = MainMenu.build(trackMenus: TrackMenus())
        let video = try #require(menu.item(withTitle: "Video")?.submenu)
        let info = try #require(video.item(withTitle: "Video Info"))
        #expect(info.keyEquivalent == "i")
        #expect(info.keyEquivalentModifierMask == .command, "Cmd+I, IINA's Inspector key")
        #expect(info.action == #selector(AppDelegate.toggleVideoInfo(_:)))

        let subtitles = try #require(menu.item(withTitle: "Subtitles")?.submenu)
        let add = try #require(subtitles.item(withTitle: "Add Subtitle File\u{2026}"))
        #expect(add.keyEquivalent == "O", "an uppercase key equivalent is Shift+Cmd+O")
        #expect(add.keyEquivalentModifierMask == .command)
        #expect(add.action == #selector(AppDelegate.addSubtitleFile(_:)))
    }

    @Test func audioMenuListsOutputDevicesWithTheChoiceChecked() throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let store = StateStore(paths: ReelPaths(home: scratch.url))
        let devices = OutputDeviceModel(stateStore: store, list: { OutputDeviceTests.devices }, log: .disabled)
        let trackMenus = TrackMenus()
        trackMenus.outputDevices = devices
        let menu = MainMenu.build(trackMenus: trackMenus)
        let audio = try #require(menu.item(withTitle: "Audio")?.submenu)
        let output = try #require(audio.item(withTitle: "Output Device")?.submenu)
        trackMenus.menuNeedsUpdate(output)
        let titles = output.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.first?.hasPrefix("System Default") == true)
        #expect(Array(titles.dropFirst()) == ["MacBook Pro Speakers", "AirPods Pro", "Display Speakers"])
        #expect(output.items[1].isSeparatorItem, "a separator after System Default")
        #expect(output.items.first?.state == .on)
        #expect(output.items.first?.attributedTitle?.string == "System Default MacBook Pro Speakers")

        devices.select(.device(uid: "airpods", name: "AirPods Pro"))
        trackMenus.menuNeedsUpdate(output)
        let checked = output.items.filter { $0.state == .on }.map(\.title)
        #expect(checked == ["AirPods Pro"])
        let choice = (output.items.first { $0.title == "AirPods Pro" }?.representedObject as? OutputDeviceMenuChoice)?.choice
        #expect(choice == .device(uid: "airpods", name: "AirPods Pro"))
        #expect(output.items.allSatisfy { $0.tag == TrackMenus.dynamicTag }, "rebuilt on every open")
    }
}

@Suite struct KeyHandlingM3Tests {
    @Test func cmdIAndEscapeOpenAndCloseVideoInfo() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let model = makeAppModel()
        let target = NullCommandTarget()
        KeyHandling.perform(.videoInfo, model: model, target: target)
        #expect(!model.videoInfoVisible, "nothing open, nothing to describe")
        await model.open(try scratch.makeFile("movie.mkv"))
        await eventually("playing") { model.playbackState == .playing }
        #expect(InputMap.standard.action(for: KeyChord(character: "i", modifiers: .command)) == .videoInfo)
        KeyHandling.perform(.videoInfo, model: model, target: target)
        #expect(model.videoInfoVisible)
        #expect(KeyHandling.handleOverlayKey(KeyChord(.escape), model: model))
        #expect(!model.videoInfoVisible)
        #expect(!KeyHandling.handleOverlayKey(KeyChord(.escape), model: model), "Esc passes on when nothing is open")
        KeyHandling.perform(.videoInfo, model: model, target: target)
        KeyHandling.perform(.videoInfo, model: model, target: target)
        #expect(!model.videoInfoVisible, "Cmd+I toggles")
    }

    @Test func shiftCmdOAsksForASubtitleFile() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let model = makeAppModel()
        var asked = 0
        model.onAddSubtitleFile = { asked += 1 }
        await model.open(try scratch.makeFile("movie.mkv"))
        await eventually("playing") { model.playbackState == .playing }
        let action = InputMap.standard.action(for: KeyChord(character: "O", modifiers: [.command]))
            ?? InputMap.standard.action(for: KeyChord(character: "o", modifiers: [.command, .shift]))
        #expect(action == .addSubtitleFile)
        KeyHandling.perform(.addSubtitleFile, model: model, target: NullCommandTarget())
        #expect(asked == 1)
    }
}

@Suite struct OcclusionTests {
    @Test func hiddenForOneSecondStopsVideoAndVisibleResumesAtOnce() {
        let clock = FakeScheduler()
        var told: [Bool] = []
        let gate = OcclusionGate(scheduler: clock) { told.append($0) }
        gate.setWindowVisible(false)
        clock.advance(by: 0.9)
        #expect(told.isEmpty, "not before EnergyPolicy.occlusionDelay")
        gate.setWindowVisible(true)
        clock.advance(by: 5)
        #expect(told.isEmpty, "visible again within the second: nothing happens")
        #expect(clock.pendingCount == 0)

        gate.setWindowVisible(false)
        clock.advance(by: 1)
        #expect(told == [true])
        #expect(gate.isOccluded)
        gate.setWindowVisible(false)
        clock.advance(by: 3)
        #expect(told == [true], "told once")
        gate.setWindowVisible(true)
        #expect(told == [true, false], "visible resyncs at once, without waiting")
    }

    @Test func pictureInPictureNeverCountsAsHidden() {
        let clock = FakeScheduler()
        var told: [Bool] = []
        let gate = OcclusionGate(scheduler: clock) { told.append($0) }
        gate.setPictureInPictureActive(true)
        gate.setWindowVisible(false)
        clock.advance(by: 10)
        #expect(told.isEmpty, "PiP shows the display layer, so video keeps decoding")
        gate.setPictureInPictureActive(false)
        clock.advance(by: 1)
        #expect(told == [true])
        gate.setPictureInPictureActive(true)
        #expect(told == [true, false], "PiP starting while hidden brings video back")
    }

    @Test func pointerActivityHoldsForTenSecondsWithOneTimer() {
        let clock = FakeScheduler()
        var changes: [Bool] = []
        let pointer = PointerActivity(now: { clock.now }, scheduler: clock) { changes.append($0) }
        pointer.moved()
        #expect(changes == [true])
        for _ in 0..<50 {
            clock.advance(by: 0.1)
            pointer.moved()
        }
        #expect(clock.pendingCount == 1, "one timer per quiet period, not one per event")
        clock.advance(by: 9.5)
        #expect(changes == [true])
        clock.advance(by: 0.6)
        #expect(changes == [true, false])
        #expect(!pointer.isRecent)
    }
}

@Suite struct DisplayRangeMonitorTests {
    @Test func pollsTheHeadroomOnlyWhileVideoInfoIsOpen() {
        let clock = FakeScheduler()
        let center = NotificationCenter()
        let display = DisplayBox(.xdr)
        var reported: [DisplayCapabilities] = []
        let monitor = DisplayRangeMonitor(window: nil, read: { display.value }, center: center, scheduler: clock) { reported.append($0) }
        defer { monitor.stop() }
        #expect(reported == [.xdr], "read once at start")
        let readsAtStart = monitor.reads
        clock.advance(by: 10)
        #expect(monitor.reads == readsAtStart, "no polling while Video Info is closed")

        monitor.setPolling(true)
        display.value = DisplayCapabilities(name: "Built-in XDR display", potentialHeadroom: 16, currentHeadroom: 5)
        clock.advance(by: 0.5)
        #expect(reported.last?.currentHeadroom == 5)
        let beforeTwoSeconds = monitor.reads
        clock.advance(by: 2)
        #expect(monitor.reads == beforeTwoSeconds + 4, "2 Hz")
        monitor.setPolling(false)
        let afterClose = monitor.reads
        clock.advance(by: 10)
        #expect(monitor.reads == afterClose)
        #expect(clock.pendingCount == 0)

        display.value = .sdr
        center.post(name: NSWindow.didChangeScreenNotification, object: nil)
        #expect(reported.last == .sdr, "moving to another screen is read at once")
    }
}

@Suite struct VolumeWatcherTests {
    static func mount(_ name: String, on center: NotificationCenter) {
        center.post(
            name: NSWorkspace.didMountNotification,
            object: nil,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: URL(filePath: "/Volumes/\(name)", directoryHint: .isDirectory)]
        )
    }

    @Test func reopensWhenTheSameDriveAndFileComeBack() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let file = try scratch.makeFile("Northern.Line.S01E01.mkv")
        let engines = EngineList()
        let model = makeAppModel(engines: engines)
        let center = NotificationCenter()
        let watcher = VolumeWatcher(model: model, center: center, log: .disabled)
        defer { watcher.stop() }
        watcher.track(file)
        await watcher.keyRead()
        #expect(watcher.key != nil)
        await model.open(file)
        await eventually("playing") { model.playbackState == .playing }
        try #require(engines.all.first).emit(.problem(.volumeGone("Eric X9 Pro")))
        await eventually("the drive card") { model.isVolumeGone }

        Self.mount("Other Drive", on: center)
        try await Task.sleep(for: .milliseconds(50))
        #expect(watcher.reopenCount == 0, "another volume is ignored")

        await watcher.volumeMounted("Eric X9 Pro")
        #expect(watcher.reopenCount == 1)
        await eventually("reopened") { engines.all.count == 2 }
        await eventually("playing again") { model.playbackState == .playing && model.problem == nil }
    }

    @Test func aDifferentFileAtTheSamePathIsNotReopened() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let file = try scratch.makeFile("movie.mkv")
        let engines = EngineList()
        let model = makeAppModel(engines: engines)
        let watcher = VolumeWatcher(model: model, center: NotificationCenter(), log: .disabled)
        defer { watcher.stop() }
        watcher.track(file)
        await watcher.keyRead()
        await model.open(file)
        await eventually("playing") { model.playbackState == .playing }
        try #require(engines.all.first).emit(.problem(.volumeGone("Eric X9 Pro")))
        await eventually("the drive card") { model.isVolumeGone }
        try Data(repeating: 7, count: 9_000).write(to: file)
        await watcher.volumeMounted("Eric X9 Pro")
        #expect(watcher.reopenCount == 0)
        #expect(engines.all.count == 1)
        #expect(model.isVolumeGone)
    }

    @Test func closeFileFromTheCardLeavesTheWatcherIdle() async throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let file = try scratch.makeFile("movie.mkv")
        let engines = EngineList()
        let model = makeAppModel(engines: engines)
        let watcher = VolumeWatcher(model: model, center: NotificationCenter(), log: .disabled)
        defer { watcher.stop() }
        watcher.track(file)
        await model.open(file)
        await eventually("playing") { model.playbackState == .playing }
        try #require(engines.all.first).emit(.problem(.volumeGone("Eric X9 Pro")))
        await eventually("the drive card") { model.isVolumeGone }
        await model.performProblemAction(.closeFile)
        #expect(!model.hasMedia)
        await watcher.volumeMounted("Eric X9 Pro")
        #expect(watcher.reopenCount == 0, "nothing to resume after Close File")
    }

    @Test func volumeNameComesFromTheMountURL() {
        let note = Notification(
            name: NSWorkspace.didMountNotification,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: URL(filePath: "/Volumes/Eric X9 Pro", directoryHint: .isDirectory)]
        )
        #expect(VolumeWatcher.volumeName(note) == "Eric X9 Pro")
    }
}

@Suite struct OutputDeviceTests {
    static let devices = [
        AudioOutputDevice(uid: "builtin", name: "MacBook Pro Speakers", isDefault: true),
        AudioOutputDevice(uid: "airpods", name: "AirPods Pro"),
        AudioOutputDevice(uid: "display", name: "Display Speakers"),
    ]

    @Test func choiceResolvesFallsBackAndRoundTripsThroughStateJSON() throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let paths = ReelPaths(home: scratch.url)
        var present = Self.devices
        let store = StateStore(paths: paths)
        let model = OutputDeviceModel(stateStore: store, list: { present }, log: .disabled)
        var announced: [String] = []
        var routed: [String?] = []
        model.onResolve = { resolution, announce in
            routed.append(resolution.uid)
            if announce, let text = resolution.osdText { announced.append(text) }
        }
        #expect(model.choice == .systemDefault)
        #expect(model.resolution.uid == nil)

        model.select(.device(uid: "airpods", name: "AirPods Pro"))
        #expect(routed.last == "airpods")
        #expect(announced.isEmpty)

        present.removeAll { $0.uid == "airpods" }
        model.refresh()
        #expect(routed.last == .some(nil), "the system default plays")
        #expect(announced == ["Audio: MacBook Pro Speakers"])
        #expect(model.choice == .device(uid: "airpods", name: "AirPods Pro"), "the choice is kept for when it returns")
        #expect(model.entries.last?.isConnected == false)
        model.refresh()
        #expect(announced.count == 1, "announced once per disappearance")
        model.reapply()
        #expect(announced.count == 2, "and again when a file opens without it")

        present = Self.devices
        model.refresh()
        #expect(routed.last == "airpods")

        try store.flush()
        let reloaded = StateStore(paths: paths)
        _ = try reloaded.load()
        #expect(reloaded.state.outputDevice == .device(uid: "airpods", name: "AirPods Pro"))
        let again = OutputDeviceModel(stateStore: reloaded, list: { Self.devices }, log: .disabled)
        #expect(again.resolution.uid == "airpods")
        #expect(again.selectedEntry?.title == "AirPods Pro")
    }
}

@Suite struct SettingsM3Tests {
    @Test func settingsHavePlaybackVideoAndAudioGroupsWithTheM3Rows() {
        let sections = SettingsSection.all
        #expect(sections.map(\.title) == ["Playback", "Video", "Audio", "Shelf"])
        #expect(sections[1].rows.contains(.highDynamicRange))
        #expect(sections[2].rows == [.outputDevice])
        #expect(sections[3].rows == [.toggle(
            "Show in Shelf",
            detail: "Shelf shows a frame from the video. Off shows only the title and time left.",
            \.showInShelf
        )])
        #expect(SettingsRow.highDynamicRange.title == "High dynamic range")
        #expect(SettingsRow.outputDevice.title == "Output device")
        #expect(HDRSetting.allCases.map(\.title) == ["Full", "Limited", "Off"])
        #expect(SettingsRow.outputDevice.detail == "System Default follows the Sound settings.")
        let toggles = sections.flatMap(\.rows).filter { if case .toggle = $0 { true } else { false } }
        #expect(toggles.count == 5, "the M1 four stay, plus Show in Shelf")
    }

    @Test func highDynamicRangeIsSavedAndReachesThePlayer() throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let paths = ReelPaths(home: scratch.url)
        let store = SettingsStore(paths: paths)
        let settings = SettingsModel(store: store, log: .disabled)
        let player = makeAppModel()
        settings.onChange = { [weak player] in player?.setHDRSetting($0.highDynamicRange) }
        settings.highDynamicRange.wrappedValue = .limited
        #expect(store.settings.highDynamicRange == .limited)
        #expect(player.hdrSetting == .limited)
        settings.setHighDynamicRange(.off)
        #expect(player.dynamicRangePlan.setting == .off)
    }
}

@Suite struct ScreenshotSaverTests {
    @Test func screenshotsGoUnderReelHome() throws {
        let scratch = try AppScratch()
        defer { scratch.remove() }
        let saver = ScreenshotSaver(environment: ReelEnvironment(["REEL_HOME": scratch.url.path(percentEncoded: false)]), log: .disabled) { _ in }
        #expect(saver.screenshotsDirectory.standardizedFileURL.path.hasPrefix(scratch.url.standardizedFileURL.path))
        #expect(!saver.screenshotsDirectory.path.contains("/Pictures/"))
    }
}

/// Regression for 57b62a8: MediaPlayer calls the artwork handler on its own queue. A closure
/// that inherited the main actor trapped in dispatch_assert_queue there.
@Suite struct NowPlayingArtworkTests {
    @Test func artworkHandlerRunsOffTheMainThread() async throws {
        let size = NSSize(width: 4, height: 3)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let jpeg = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .jpeg, properties: [:]))
        let artwork = NowPlayingArtworkBox(SystemNowPlayingPublisher.artwork(jpeg: jpeg, size: size))
        let result: (width: Double, onMain: Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let image = artwork.value.image(at: CGSize(width: 4, height: 3))
                continuation.resume(returning: (Double(image?.size.width ?? 0), Thread.isMainThread))
            }
        }
        #expect(!result.onMain)
        #expect(result.width > 0, "an image comes back")
    }
}

nonisolated final class NowPlayingArtworkBox: @unchecked Sendable {
    let value: MPMediaItemArtwork
    init(_ value: MPMediaItemArtwork) { self.value = value }
}
