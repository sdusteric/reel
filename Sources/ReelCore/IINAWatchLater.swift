import CryptoKit
import Foundation

/// Read-only access to IINA's mpv watch_later files, used as a fallback when Reel has no entry
/// (design section 11.2). Reel never writes there.
public struct IINAWatchLater: Sendable, Hashable {
    /// Nil disables the carry-over.
    public let directory: URL?

    public init(directory: URL?) {
        self.directory = directory
    }

    /// Uses `REEL_IINA_WATCH_LATER` when set (empty disables), else IINA's default folder.
    public init(environment: ReelEnvironment) {
        self.init(directory: environment.iinaWatchLaterDirectory)
    }

    /// mpv names the file by the uppercase hex MD5 of the absolute path.
    public static func fileName(forPath path: String) -> String {
        Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    public func fileURL(forPath path: String) -> URL? {
        directory?.appending(path: IINAWatchLater.fileName(forPath: path), directoryHint: .notDirectory)
    }

    /// The saved `start=` position for `mediaURL`, or nil when disabled, absent or unparsable.
    /// Other read errors are thrown.
    public func startPosition(forFileAt mediaURL: URL) throws -> MediaTime? {
        guard let url = fileURL(forPath: mediaURL.path(percentEncoded: false)) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        return IINAWatchLater.parseStart(String(decoding: data, as: UTF8.self))
    }

    /// Finds `start=<seconds>` in the file text. The last valid line wins; negative or
    /// non-finite values are ignored.
    public static func parseStart(_ text: String) -> MediaTime? {
        var result: MediaTime?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("start=") else { continue }
            let value = line.dropFirst("start=".count).trimmingCharacters(in: .whitespaces)
            if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
                result = MediaTime(seconds: seconds)
            }
        }
        return result
    }
}
