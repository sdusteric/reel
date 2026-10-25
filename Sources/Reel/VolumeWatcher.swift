import AppKit
import ReelCore
import ReelUI

/// Reopens a file whose drive was disconnected (section 7.10, D64). The engine reports
/// `.volumeGone(name)` and the model pauses on the dimmed frame with the card; when a volume with
/// that name mounts again and the file at the same path has the same content key, this reopens it,
/// which resumes at the saved time and plays. Try Again and Close File are the card's own buttons
/// (`PlayerModel.performProblemAction`). It never lists `/Volumes`: names come from the
/// mount notifications, and only the one file is read.
@MainActor
final class VolumeWatcher {
    typealias KeyReader = @Sendable (URL) throws -> ContentKey

    private let model: PlayerModel
    private let center: NotificationCenter
    private let contentKey: KeyReader
    private let fileExists: @Sendable (URL) -> Bool
    private let log: ReelLog
    private var observers: [NSObjectProtocol] = []
    /// The file last asked to open, and its content key once read.
    private(set) var file: URL?
    private(set) var key: ContentKey?
    private var keyTask: Task<Void, Never>?
    /// Reopens started by a mount (tests).
    private(set) var reopenCount = 0
    private var reopening = false

    init(
        model: PlayerModel,
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        contentKey: @escaping KeyReader = { try ContentKey(contentsOf: $0) },
        fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) },
        log: ReelLog
    ) {
        self.model = model
        self.center = center
        self.contentKey = contentKey
        self.fileExists = fileExists
        self.log = log
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let name = VolumeWatcher.volumeName(note)
            MainActor.assumeIsolated {
                guard let self, let name else { return }
                Task { await self.volumeMounted(name) }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let name = VolumeWatcher.volumeName(note)
            MainActor.assumeIsolated {
                guard let self, let name else { return }
                self.volumeUnmounted(name)
            }
        })
    }

    /// The volume's name from a mount notification: the last path component of its URL
    /// (`/Volumes/<name>`), which is what `MediaProblem.volumeName(of:)` takes from a file path.
    nonisolated static func volumeName(_ note: Notification) -> String? {
        if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            return url.lastPathComponent
        }
        return note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String
    }

    /// A file is being opened (or opened by episode navigation): remember it and read its key in
    /// the background while the drive is still there.
    func track(_ url: URL?) {
        guard let url, url.standardizedFileURL != file?.standardizedFileURL else { return }
        file = url
        key = nil
        keyTask?.cancel()
        let reader = contentKey
        keyTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { try? reader(url) }.value
            guard !Task.isCancelled, let self, self.file == url else { return }
            self.key = result
        }
    }

    /// Tests: waits for the key read of the tracked file.
    func keyRead() async {
        await keyTask?.value
    }

    func volumeMounted(_ name: String) async {
        guard case .volumeGone(let gone)? = model.problem, gone == name, let file, !reopening else { return }
        guard fileExists(file) else {
            log.info("\(name) mounted, but \(file.lastPathComponent) is not there")
            return
        }
        if let key {
            let reader = contentKey
            let mounted = await Task.detached(priority: .userInitiated) { try? reader(file) }.value
            guard mounted == key else {
                log.info("\(name) mounted, but \(file.lastPathComponent) has different contents; not reopening")
                return
            }
        }
        log.info("\(name) mounted again; reopening \(file.lastPathComponent)")
        reopening = true
        reopenCount += 1
        defer { reopening = false }
        await model.performProblemAction(.tryAgain)
    }

    func volumeUnmounted(_ name: String) {
        guard let file, MediaProblem.volumeName(of: file.path(percentEncoded: false)) == name else { return }
        log.info("\(name) was unmounted while \(file.lastPathComponent) is open")
    }

    func stop() {
        keyTask?.cancel()
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}
