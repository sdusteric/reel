import AppKit
import Foundation
import MediaPlayer
import ReelCore
import ReelUI

/// What the system's Now Playing shows for the open file (design 9.10).
struct NowPlayingState: Equatable {
    var title: String
    var duration: Double?
    var elapsed: Double
    /// The rate in force; Now Playing extrapolates the elapsed time with it while playing.
    var rate: Double
    var isPlaying: Bool
    var hasNext: Bool
    var hasPrevious: Bool
    /// The current thumbnail, JPEG (the engine's thumbnail store).
    var artwork: Data?
}

/// A command from the media keys, the Control Centre or a headset, through
/// `MPRemoteCommandCenter`.
enum RemoteCommand: Equatable {
    case play, pause, togglePlayPause
    case nextTrack, previousTrack
    /// Seconds from the start.
    case changePosition(Double)
    case skipForward(Double)
    case skipBackward(Double)
}

/// Publishes Now Playing info. The app uses `MPNowPlayingInfoCenter`; tests use a fake, so no
/// test ever registers with the real centre.
protocol NowPlayingPublishing: AnyObject {
    /// nil clears the info and gives up the media keys.
    func publish(_ state: NowPlayingState?)
}

/// Registers remote command handlers. The app uses `MPRemoteCommandCenter`; tests use a fake.
protocol RemoteCommandRegistering: AnyObject {
    func register(handler: @escaping @MainActor (RemoteCommand) -> Void)
    func setEpisodeCommandsEnabled(next: Bool, previous: Bool)
    func unregister()
}

/// Now Playing and media keys (design 9.10, D44): registered only while a file is open, updated on
/// play, pause, seek settle, rate change and every 5 s (never on every time tick), cleared on close.
@MainActor
final class NowPlaying {
    static let refreshInterval: TimeInterval = 5
    /// Skip forward and back: the controller's 10 s step (`PlayerModel.buttonSeekStep`).
    nonisolated static let skipInterval: Double = 10

    private let publisher: NowPlayingPublishing
    private let commands: RemoteCommandRegistering
    private var registered = false
    private var lastPublished: NowPlayingState?
    private var timer: Task<Void, Never>?
    private let sleep: (TimeInterval) async -> Void

    init(
        publisher: NowPlayingPublishing,
        commands: RemoteCommandRegistering,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.publisher = publisher
        self.commands = commands
        self.sleep = sleep
    }

    var isRegistered: Bool { registered }

    /// The state to show for `model`, or nil when nothing is open.
    static func state(for model: PlayerModel, artwork: Data?) -> NowPlayingState? {
        guard model.hasMedia, let media = model.media else { return nil }
        // The episode name ("Northern Line S01E02"), else the stem with dots as spaces.
        let title = EpisodeList.episodeName(for: media.url)
        return NowPlayingState(
            title: title.isEmpty ? media.url.lastPathComponent : title,
            duration: model.duration?.seconds,
            elapsed: model.position.seconds,
            rate: model.rate,
            isPlaying: model.isPlaying,
            hasNext: model.hasNextEpisode,
            hasPrevious: model.hasPreviousEpisode,
            artwork: artwork
        )
    }

    /// Publishes `state`, registering the commands on the first file and clearing on close.
    /// `model` receives the commands.
    func update(_ state: NowPlayingState?, model: PlayerModel) {
        guard let state else {
            clear()
            return
        }
        if !registered {
            registered = true
            commands.register { [weak model] command in
                guard let model else { return }
                NowPlaying.perform(command, on: model)
            }
            startTimer(model: model)
        }
        commands.setEpisodeCommandsEnabled(next: state.hasNext, previous: state.hasPrevious)
        guard state != lastPublished else { return }
        lastPublished = state
        publisher.publish(state)
    }

    /// Nothing is open: stop claiming the media keys.
    func clear() {
        timer?.cancel()
        timer = nil
        guard registered || lastPublished != nil else { return }
        registered = false
        lastPublished = nil
        commands.unregister()
        publisher.publish(nil)
    }

    /// The 5 s refresh while a file is open; `onTick` supplies the fresh state.
    var onTick: (() -> Void)?

    private func startTimer(model: PlayerModel) {
        timer?.cancel()
        let sleep = sleep
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(NowPlaying.refreshInterval)
                guard !Task.isCancelled, let self else { return }
                self.onTick?()
            }
        }
    }

    /// Maps a remote command to the player (design 9.10).
    static func perform(_ command: RemoteCommand, on model: PlayerModel) {
        switch command {
        case .play: model.play()
        case .pause: model.pause()
        case .togglePlayPause: model.togglePause()
        case .nextTrack: Task { await model.playNextEpisode() }
        case .previousTrack: Task { await model.playPreviousEpisode() }
        case .changePosition(let seconds): model.seek(to: .seconds(seconds), source: .pointer)
        case .skipForward(let seconds): model.seek(by: seconds, source: .pointer)
        case .skipBackward(let seconds): model.seek(by: -seconds, source: .pointer)
        }
    }
}

// MARK: System adapters (the app only)

/// `MPNowPlayingInfoCenter.default()`, touched only once a file is open.
final class SystemNowPlayingPublisher: NowPlayingPublishing {
    func publish(_ state: NowPlayingState?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let state else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? state.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let duration = state.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let jpeg = state.artwork, let image = NSImage(data: jpeg) {
            info[MPMediaItemPropertyArtwork] = Self.artwork(jpeg: jpeg, size: image.size)
        }
        center.nowPlayingInfo = info
        center.playbackState = state.isPlaying ? .playing : .paused
    }

    /// MediaPlayer calls the artwork handler on its own queue, so the closure must not inherit the
    /// main actor (a main-actor closure traps in dispatch_assert_queue there).
    nonisolated private static func artwork(jpeg: Data, size: CGSize) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
            NSImage(data: jpeg) ?? NSImage()
        }
    }
}

/// `MPRemoteCommandCenter.shared()`: play, pause, toggle, next and previous episode, change
/// position, skip 10 s.
final class SystemRemoteCommands: RemoteCommandRegistering {
    private var tokens: [(MPRemoteCommand, Any)] = []

    func register(handler: @escaping @MainActor (RemoteCommand) -> Void) {
        unregister()
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: NowPlaying.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: NowPlaying.skipInterval)]
        let simple: [(MPRemoteCommand, RemoteCommand)] = [
            (center.playCommand, .play),
            (center.pauseCommand, .pause),
            (center.togglePlayPauseCommand, .togglePlayPause),
            (center.nextTrackCommand, .nextTrack),
            (center.previousTrackCommand, .previousTrack),
        ]
        for (command, value) in simple {
            add(command) { _ in value }
        }
        add(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .changePosition($0.positionTime) }
        }
        add(center.skipForwardCommand) { event in
            .skipForward((event as? MPSkipIntervalCommandEvent)?.interval ?? NowPlaying.skipInterval)
        }
        add(center.skipBackwardCommand) { event in
            .skipBackward((event as? MPSkipIntervalCommandEvent)?.interval ?? NowPlaying.skipInterval)
        }

        func add(_ command: MPRemoteCommand, _ translate: @escaping @Sendable (MPRemoteCommandEvent) -> RemoteCommand?) {
            command.isEnabled = true
            let token = command.addTarget { @Sendable event in
                guard let value = translate(event) else { return .commandFailed }
                Task { @MainActor in handler(value) }
                return .success
            }
            tokens.append((command, token))
        }
    }

    func setEpisodeCommandsEnabled(next: Bool, previous: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = next
        center.previousTrackCommand.isEnabled = previous
    }

    func unregister() {
        for (command, token) in tokens {
            command.removeTarget(token)
            command.isEnabled = false
        }
        tokens.removeAll()
    }
}
