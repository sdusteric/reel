import CoreGraphics
import CoreServices
import Foundation
import ReelCore
import ReelEngine
import ReelUI

/// The episode list of design 9.8: lists the open file's folder with `EpisodeList` and watches
/// that one folder with FSEvents while the file is open, so the list follows files being added,
/// renamed or removed. If the folder cannot be listed (access denied, D48) the list is nil and
/// the episode buttons hide; nothing else changes.
@MainActor
final class EpisodeNavigator {
    /// FSEvents coalesces changes for this long before calling back.
    static let latency: CFTimeInterval = 1

    private let log: ReelLog
    private var stream: FSEventStreamRef?
    private var box: Unmanaged<WatchBox>?
    private(set) var watchedFolder: URL?
    /// Called on the main actor when the watched folder's listing changed.
    var onFolderChange: (() -> Void)?

    init(log: ReelLog) {
        self.log = log
    }

    /// `PlayerModel.Dependencies.episodeList`: one level of the file's folder, or nil.
    nonisolated static func scanner(log: ReelLog) -> @Sendable (URL) -> EpisodeList? {
        { url in
            do {
                return try EpisodeList.scan(current: url)
            } catch {
                log.info("episode list unavailable for \(url.deletingLastPathComponent().lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// Watches the folder of `file`, or stops watching when `file` is nil. Watching the same
    /// folder again does nothing.
    func watch(fileAt file: URL?) {
        let folder = file?.deletingLastPathComponent().standardizedFileURL
        guard folder != watchedFolder else { return }
        stop()
        guard let folder else { return }
        start(folder)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        box?.release()
        box = nil
        watchedFolder = nil
    }

    private func start(_ folder: URL) {
        let path = folder.path(percentEncoded: false)
        // FSEvents reports resolved paths (/private/var for /var), so match against both.
        let resolved = folder.resolvingSymlinksInPath().path(percentEncoded: false)
        let watch = WatchBox(folderPaths: [path, resolved]) { [weak self] in self?.onFolderChange?() }
        let retained = Unmanaged.passRetained(watch)
        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<WatchBox>.fromOpaque(info).takeUnretainedValue()
            guard let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let changed = list.prefix(count).contains { watch.matches($0) }
            guard changed else { return }
            // The stream runs on the main queue.
            MainActor.assumeIsolated { watch.handler() }
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            EpisodeNavigator.latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else {
            retained.release()
            log.info("could not watch \(folder.lastPathComponent) for new episodes")
            return
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            retained.release()
            log.info("could not watch \(folder.lastPathComponent) for new episodes")
            return
        }
        stream = created
        box = retained
        watchedFolder = folder
    }
}

/// What the FSEvents callback needs: the folder and the handler. Only events for the folder
/// itself count; FSEvents also reports its subfolders.
private final class WatchBox: @unchecked Sendable {
    // Read on the main queue only: the stream is scheduled there.
    let folderPaths: Set<String>
    let handler: @MainActor () -> Void

    init(folderPaths: [String], handler: @escaping @MainActor () -> Void) {
        self.folderPaths = Set(folderPaths.map(WatchBox.trimmed))
        self.handler = handler
    }

    func matches(_ path: String) -> Bool {
        folderPaths.contains(WatchBox.trimmed(path))
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

extension EpisodeNavigator {
    /// Where the next-episode card's picture comes from: 30 s in, so the cold open is not given
    /// away (D39); the first frame for shorter files.
    nonisolated static let cardFrameTime = MediaTime.seconds(30)
    /// The card shows 128 x 72 pt; 2x of that is kept, not the full decoded frame.
    nonisolated static let cardImageWidth = 256

    /// `PlayerModel.Dependencies.episodeThumbnail`: decodes one frame off the main actor.
    nonisolated static func cardThumbnail(for url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) {
            let frame: CGImage
            do {
                frame = try FrameGrabber.grabImage(url: url, at: cardFrameTime)
            } catch {
                do {
                    frame = try FrameGrabber.grabImage(url: url, at: .zero)
                } catch {
                    return nil
                }
            }
            return scaled(frame, width: cardImageWidth)
        }.value
    }

    nonisolated static func scaled(_ image: CGImage, width: Int) -> CGImage? {
        guard image.width > width, image.width > 0 else { return image }
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
