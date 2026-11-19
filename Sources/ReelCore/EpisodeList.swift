import Foundation

/// The playable videos in the open file's folder, in natural order (design section 9.8).
public struct EpisodeList: Sendable, Hashable {
    /// Extensions Reel opens as video (section 5).
    public static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "flv", "avi", "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "m2v", "ogv",
    ]

    public let files: [URL]
    /// Position of the current file in `files`; nil when it is not in the list.
    public let currentIndex: Int?

    /// Builds the list for `current` from a folder listing (files of that one folder).
    public init(current: URL, folderContents: [URL]) {
        let folder = current.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        var unique: [String: URL] = [:]
        for url in folderContents + [current] where EpisodeList.isPlayableVideo(url) {
            let standardized = url.standardizedFileURL
            guard standardized.deletingLastPathComponent().path(percentEncoded: false) == folder else { continue }
            unique[standardized.lastPathComponent] = standardized
        }
        files = unique.values.sorted { lhs, rhs in
            let order = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
            return order == .orderedSame ? lhs.lastPathComponent < rhs.lastPathComponent : order == .orderedAscending
        }
        let name = current.standardizedFileURL.lastPathComponent
        currentIndex = files.firstIndex { $0.lastPathComponent == name }
    }

    /// Lists `current`'s folder (one level, no recursion). Throws when the folder cannot be read,
    /// for example when folder access was denied (the episode buttons then hide, D48).
    public static func scan(current: URL, fileManager: FileManager = .default) throws -> EpisodeList {
        // Paths are compared as the file system spells them: a path given in another case (the
        // volume is case-insensitive) or through a symlink would otherwise match no listed file.
        let current = canonical(current)
        let folder = current.deletingLastPathComponent()
        let contents = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .canonicalPathKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let files = contents.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        }
        return EpisodeList(current: current, folderContents: files.map(canonical))
    }

    /// The file system's own spelling of `url` (case as stored, symlinks resolved), or the
    /// standardized URL when it cannot be read.
    public static func canonical(_ url: URL) -> URL {
        guard let path = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath else {
            return url.standardizedFileURL
        }
        return URL(filePath: path, directoryHint: .notDirectory)
    }

    /// A video by extension, not hidden and not an AppleDouble `._` file.
    public static func isPlayableVideo(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), !url.hasDirectoryPath else { return false }
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    public var count: Int { files.count }

    /// The file is alone in its folder: previous and next are hidden (D28).
    public var isAlone: Bool { files.count <= 1 }

    public var current: URL? { currentIndex.map { files[$0] } }

    public var next: URL? {
        guard let currentIndex, currentIndex + 1 < files.count else { return nil }
        return files[currentIndex + 1]
    }

    public var previous: URL? {
        guard let currentIndex, currentIndex > 0 else { return nil }
        return files[currentIndex - 1]
    }

    /// Files after the current one, nearest first, for skipping files that fail to open.
    public func following(limit: Int) -> [URL] {
        guard let currentIndex else { return [] }
        return Array(files.dropFirst(currentIndex + 1).prefix(limit))
    }

    /// "Northern.Line.S02E06.1080p.BluRay.mkv" gives "Northern Line S02E06": the stem up to the
    /// SxxEyy or Exx token, with dots and underscores as spaces; else the whole stem so treated.
    public static func episodeName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let prefix = episodePrefix(stem) ?? stem
        return prefix
            .replacing(/[._]+/, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func episodePrefix(_ stem: String) -> String? {
        if let match = stem.firstMatch(of: /(?i)^(.*?s\d{1,2}[ ._-]?e\d{1,4})(?!\d)/) {
            return String(match.1)
        }
        if let match = stem.firstMatch(of: /(?i)^(.*?(?:^|[ ._\-\[])e(?:p)?\d{1,4})(?![\dp])/) {
            return String(match.1)
        }
        return nil
    }
}
